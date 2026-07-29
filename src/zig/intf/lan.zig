//! Port of `src/plugins/lan/lan.c`: the IPMI v1.5 / RMCP LAN transport.
//!
//! The wire format is the one drawn in the C source:
//!
//! ```text
//! rmcp header        4 bytes
//! session header     9 bytes   authtype, inbound sequence, session id
//! [authcode]        16 bytes   only when the session is active and authenticated
//! message length     1 byte
//! ipmi message       6 bytes   rs_addr, netfn/lun, csum1, rq_addr, rq_seq/lun, cmd
//! [request data]
//! csum2              1 byte
//! ```
//!
//! A bridged request wraps that in one or two `Send Message` (netfn App, cmd
//! `0x34`) envelopes, each with its own pair of checksums, and the response is
//! unwrapped one envelope at a time on the way back.
//!
//! `tests/transport/` is what actually verifies this module: every datagram it
//! writes is byte-compared against a checked-in transcript *and* independently
//! validated by the model BMC in `tests/transport/Bmc.zig`.  The golden CLI
//! suite runs through `dummy` and cannot see any of it.
//!
//! ## Upstream behaviour reproduced deliberately
//!
//! 1. `ipmi_req_clear_entries()` frees each entry but never frees the
//!    `msg_data` hanging off it, so every packet buffer built for a command
//!    that was answered out of band is leaked.  `ipmi_req_remove_entry()` on
//!    the same struct does free it.
//! 2. `get_random()` returns `errno` on failure, which is a positive number, so
//!    a caller checking `< 0` sees success.  Nothing checks it at all here.
//!    The `len < 0` branch also returns a stale `errno` from a call that
//!    succeeded, which upstream flags with its own `XXX: ORLY?`.
//! 3. `ipmi_lan_recv_packet()` writes `rsp.data[ret]` after a `recv()` of up to
//!    `IPMI_BUF_SIZE` bytes, one past the end of the buffer when the datagram
//!    fills it.
//! 4. `ipmi_handle_pong()` reads a `struct rmcp_pong` out of the response
//!    without checking that `data_len` is at least that long.
//! 5. `ipmi_lan_send_cmd()` removes the request entry with
//!    `entry->req.msg.target_cmd` after a send failure, but the entry was
//!    filed under `cmd`; for an unbridged request `target_cmd` is 0, so the
//!    lookup misses and the entry stays on the list.
//! 6. The retransmit loop calls `ipmi_lan_build_cmd()` again on every attempt,
//!    which allocates a fresh `msg_data` for the *same* entry and drops the
//!    previous buffer on the floor unless the entry is looked up again.
//! 7. `ipmi_lan_build_cmd()` returns NULL on `malloc` failure *after* the entry
//!    has been added to the list, leaving an entry with no `msg_data`.
//! 8. The inbound sequence number is only advanced when it is already non-zero,
//!    so a session whose activation returned zero never increments it.  The
//!    activation path separately forces a zero to one.
//! 9. `ipmi_lan_close()` ends with `intf = NULL`, which assigns to the local
//!    parameter and does nothing.
//! 10. `ipmi_lan_open()` overwrites the `s` it just read from `intf->session`
//!     with a fresh allocation without freeing the old one; on the only path
//!     that reaches it `intf->session` is NULL, so it is not a leak in
//!     practice.
//! 11. `ipmi_lan_poll_recv()` parses the session header before checking that
//!     the datagram is long enough to contain one.
//! 12. The `!intf` guard in `ipmi_lan_open()` is dead: the vtable's parameter
//!     type is a non-optional pointer here, so it has no Zig counterpart.
//!     `ipmi_lan_close()`'s `intf->session` check is kept, because that field
//!     really can be NULL.

const builtin = @import("builtin");
const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const intf_mod = @import("intf.zig");
const log = @import("../util/log.zig");

const Intf = intf_mod.Intf;
const Session = intf_mod.Session;
const Entry = ipmi.RequestEntry;

/// `IPMI_LAN_TIMEOUT`.
const lan_timeout = 2;

/// `IPMI_LAN_RETRY`.
const lan_retry = 4;

/// `IPMI_LAN_PORT`.
const lan_port = 0x26f;

/// `IPMI_LAN_CHANNEL_E`.
const lan_channel_e = 0x0e;

/// `IPMI_LAN_MAX_REQUEST_SIZE`: 45 byte request transactions, less 7.
const max_request_size = 38;

/// `IPMI_LAN_MAX_RESPONSE_SIZE`: 42 byte response transactions, less 8.
const max_response_size = 34;

// ---------------------------------------------------------------------------
// RMCP and ASF headers
// ---------------------------------------------------------------------------

/// `RMCP_VERSION_1`.
const rmcp_version_1 = 0x06;

/// `RMCP_CLASS_ASF`.
const rmcp_class_asf = 0x06;

/// `RMCP_CLASS_IPMI`.
const rmcp_class_ipmi = 0x07;

/// `ASF_RMCP_IANA`, fixed by the ASF specification.
const asf_rmcp_iana = 0x000011be;

/// `ASF_TYPE_PING`.
const asf_type_ping = 0x80;

/// `struct rmcp_hdr`.
pub const RmcpHdr = extern struct {
    ver: u8,
    __reserved: u8,
    seq: u8,
    class: u8,
};

/// `struct asf_hdr`.
pub const AsfHdr = extern struct {
    iana: u32,
    type: u8,
    tag: u8,
    __reserved: u8,
    len: u8,
};

/// `struct rmcp_pong`.
pub const RmcpPong = extern struct {
    rmcp: RmcpHdr,
    asf: AsfHdr,
    iana: u32,
    oem: u32,
    sup_entities: u8,
    sup_interact: u8,
    reserved: [6]u8,
};

// ---------------------------------------------------------------------------
// Request list
// ---------------------------------------------------------------------------

/// `struct ipmi_rq_entry *ipmi_req_entries`.  External linkage upstream even
/// though nothing outside this file uses it.
var req_entries: ?*Entry = null;

/// `static struct ipmi_rq_entry *ipmi_req_entries_tail`.
var req_entries_tail: ?*Entry = null;

/// `static uint8_t bridge_possible`.
var bridge_possible: u8 = 0;

fn reqAddEntry(intf: *Intf, req: *ipmi.Request, req_seq: u8) ?*Entry {
    const e: *Entry = @ptrCast(@alignCast(c.malloc(@sizeOf(Entry)) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return null;
    }));

    e.* = std.mem.zeroes(Entry);
    e.req = req.*;

    e.intf = intf;
    e.rq_seq = req_seq;

    if (req_entries == null) {
        req_entries = e;
    } else {
        req_entries_tail.?.next = e;
    }

    req_entries_tail = e;
    c.lprintf(
        log.Level.debug + 3,
        "added list entry seq=0x%02x cmd=0x%02x",
        @as(c_int, e.rq_seq),
        @as(c_int, e.req.msg.cmd),
    );
    return e;
}

fn reqLookupEntry(seq: u8, cmd: u8) ?*Entry {
    var e = req_entries;
    while (e) |cur| {
        if (cur.rq_seq == seq and cur.req.msg.cmd == cmd) break;
        const next = cur.next orelse return null;
        if (next == cur) return null;
        e = next;
    }
    return e;
}

fn reqRemoveEntry(seq: u8, cmd: u8) void {
    var e = req_entries;
    var p = req_entries;

    while (e) |cur| {
        if (cur.rq_seq == seq and cur.req.msg.cmd == cmd) break;
        p = e;
        e = cur.next;
    }
    if (e) |cur| {
        c.lprintf(
            log.Level.debug + 3,
            "removed list entry seq=0x%02x cmd=0x%02x",
            @as(c_int, seq),
            @as(c_int, cmd),
        );
        const saved_next_entry = cur.next;
        // `p` is `e` itself when the match is the head, so this writes through
        // the entry that is about to be freed.
        p.?.next = if (p.?.next == cur.next) null else cur.next;
        if (req_entries == cur) {
            if (req_entries != p) {
                req_entries = p;
            } else {
                req_entries = saved_next_entry;
            }
        }
        if (req_entries_tail == cur) {
            if (req_entries_tail != p) {
                req_entries_tail = p;
            } else {
                req_entries_tail = null;
            }
        }
        if (cur.msg_data) |d| {
            c.free(d);
            cur.msg_data = null;
        }
        c.free(cur);
    }
}

/// Note 1: `msg_data` is not freed here.
fn reqClearEntries() void {
    var e = req_entries;
    while (e) |cur| {
        c.lprintf(
            log.Level.debug + 3,
            "cleared list entry seq=0x%02x cmd=0x%02x",
            @as(c_int, cur.rq_seq),
            @as(c_int, cur.req.msg.cmd),
        );
        if (cur.next) |next| {
            c.free(cur);
            e = next;
        } else {
            c.free(cur);
            e = null;
            break;
        }
    }
    req_entries = null;
    req_entries_tail = null;
}

// ---------------------------------------------------------------------------
// fd_set, which is macros in C
// ---------------------------------------------------------------------------

const fd_mask_bits = @bitSizeOf(c.__fd_mask);

fn fdZero(set: *c.fd_set) void {
    @memset(&set.__fds_bits, 0);
}

fn fdSet(fd: c_int, set: *c.fd_set) void {
    const bit: usize = @intCast(fd);
    set.__fds_bits[bit / fd_mask_bits] |= @as(c.__fd_mask, 1) << @intCast(bit % fd_mask_bits);
}

fn fdIsSet(fd: c_int, set: *const c.fd_set) bool {
    const bit: usize = @intCast(fd);
    const mask = @as(c.__fd_mask, 1) << @intCast(bit % fd_mask_bits);
    return (set.__fds_bits[bit / fd_mask_bits] & mask) != 0;
}

// ---------------------------------------------------------------------------
// Randomness
// ---------------------------------------------------------------------------

/// `get_random()`.  Note 2: every return value here is wrong in some way, and
/// the single caller ignores it.
fn getRandom(data: [*]u8, len: c_int) c_int {
    const fd = c.open("/dev/urandom", c.O_RDONLY);

    if (fd < 0) return std.c._errno().*;
    if (len < 0) {
        _ = c.close(fd);
        return std.c._errno().*;
    }

    const rv = c.read(fd, data, @intCast(len));

    _ = c.close(fd);
    return @intCast(rv);
}

// ---------------------------------------------------------------------------
// Packet I/O
// ---------------------------------------------------------------------------

fn sendPacket(intf: *Intf, data: [*]u8, data_len: c_int) c_int {
    if (c.verbose > 2) c.printbuf(data, data_len, "send_packet");

    return @intCast(c.send(intf.fd, data, @intCast(data_len), 0));
}

/// The `static struct ipmi_rs rsp` inside `ipmi_lan_recv_packet()`.
var recv_rsp: ipmi.Response = std.mem.zeroes(ipmi.Response);

fn recvPacket(intf: *Intf) ?*ipmi.Response {
    var read_set: c.fd_set = undefined;
    var err_set: c.fd_set = undefined;
    var tmout: c.struct_timeval = undefined;
    var ret: c_int = 0;

    fdZero(&read_set);
    fdSet(intf.fd, &read_set);

    fdZero(&err_set);
    fdSet(intf.fd, &err_set);

    tmout.tv_sec = @intCast(intf.ssn_params.timeout);
    tmout.tv_usec = 0;

    ret = c.select(intf.fd + 1, &read_set, null, &err_set, &tmout);
    if (ret < 0 or fdIsSet(intf.fd, &err_set) or !fdIsSet(intf.fd, &read_set)) return null;

    // The first read may return ECONNREFUSED because the RMCP ping packet --
    // sent to UDP port 623 -- is processed by both the BMC and the OS, and the
    // error is delivered ahead of any datagram already queued.
    ret = @intCast(c.recv(intf.fd, &recv_rsp.data, ipmi.buf_size, 0));

    if (ret < 0) {
        fdZero(&read_set);
        fdSet(intf.fd, &read_set);

        fdZero(&err_set);
        fdSet(intf.fd, &err_set);

        tmout.tv_sec = @intCast(intf.ssn_params.timeout);
        tmout.tv_usec = 0;

        ret = c.select(intf.fd + 1, &read_set, null, &err_set, &tmout);
        if (ret < 0 or fdIsSet(intf.fd, &err_set) or !fdIsSet(intf.fd, &read_set)) return null;

        ret = @intCast(c.recv(intf.fd, &recv_rsp.data, ipmi.buf_size, 0));
        if (ret < 0) return null;
    }

    if (ret == 0) return null;

    // Note 3: one past the end when the datagram fills the buffer.
    recv_rsp.data[@intCast(ret)] = 0;
    recv_rsp.data_len = ret;

    if (c.verbose > 2) c.printbuf(&recv_rsp.data, recv_rsp.data_len, "recv_packet");

    return &recv_rsp;
}

/// `ipmi_handle_pong()`.  Note 4: the pong is read without a length check.
fn handlePong(rsp: ?*ipmi.Response) c_int {
    const r = rsp orelse return -1;

    // `rsp->data` starts one byte into `struct ipmi_rs`, so this pointer is
    // unaligned; the C headers mark all three structs `__attribute__((packed))`
    // and the layout is byte-identical either way.
    const pong: *align(1) const RmcpPong = @ptrCast(&r.data);

    c.lprintf(
        log.Level.debug,
        "Received IPMI/RMCP response packet: \n" ++
            "  IPMI%s Supported\n" ++
            "  ASF Version %s\n" ++
            "  RMCP Version %s\n" ++
            "  RMCP Sequence %d\n" ++
            "  IANA Enterprise %ld\n",
        pick((pong.sup_entities & 0x80) != 0, "", " NOT"),
        pick((pong.sup_entities & 0x01) != 0, "1.0", "unknown"),
        pick(pong.rmcp.ver == 6, "1.0", "unknown"),
        @as(c_int, pong.rmcp.seq),
        @as(c_long, std.mem.bigToNative(u32, pong.iana)),
    );

    return if ((pong.sup_entities & 0x80) != 0) 1 else 0;
}

/// `ipmi_lan_ping()`: build and send the RMCP presence ping.
fn lanPing(intf: *Intf) c_int {
    const asf_ping: AsfHdr = .{
        .iana = std.mem.nativeToBig(u32, asf_rmcp_iana),
        .type = asf_type_ping,
        .tag = 0,
        .__reserved = 0,
        .len = 0,
    };
    const rmcp_ping: RmcpHdr = .{
        .ver = rmcp_version_1,
        .__reserved = 0,
        .seq = 0xff,
        .class = rmcp_class_asf,
    };
    const len = @sizeOf(RmcpHdr) + @sizeOf(AsfHdr);

    const data: [*]u8 = @ptrCast(c.malloc(len) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return -1;
    });
    @memset(data[0..len], 0);
    @memcpy(data[0..@sizeOf(RmcpHdr)], std.mem.asBytes(&rmcp_ping));
    @memcpy(data[@sizeOf(RmcpHdr)..][0..@sizeOf(AsfHdr)], std.mem.asBytes(&asf_ping));

    c.lprintf(log.Level.debug, "Sending IPMI/RMCP presence ping packet");

    const rv = sendPacket(intf, data, len);

    c.free(data);

    if (rv < 0) {
        c.lprintf(log.Level.err, "Unable to send IPMI presence ping packet");
        return -1;
    }

    if (pollRecv(intf) == null) return 0;

    return 1;
}

/// The "thump" functions send an extra packet after each request, which
/// kick-starts BMCs that get confused by bad passwords or heavy load.
fn thumpFirst(intf: *Intf) void {
    var data = [16]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x20, 0x18, 0xc8, 0xc2, 0x01, 0x01, 0x3c,
    };
    _ = sendPacket(intf, &data, 16);
}

fn thump(intf: *Intf) void {
    var data = [_]u8{ 't', 'h', 'u', 'm', 'p', 0, 0, 0, 0, 0 };
    _ = sendPacket(intf, &data, 10);
}

// ---------------------------------------------------------------------------
// Receive path
// ---------------------------------------------------------------------------

fn pollRecv(intf: *Intf) ?*ipmi.Response {
    var rmcp_rsp: RmcpHdr = undefined;
    var x: c_int = 0;
    var our_address: u8 = @truncate(intf.my_addr);

    if (our_address == 0) our_address = ipmi.bmc_slave_addr;

    var rsp = recvPacket(intf);

    outer: while (rsp) |r| {
        @memcpy(std.mem.asBytes(&rmcp_rsp), r.data[0..4]);

        if (rmcp_rsp.class == rmcp_class_asf) {
            // Ping response packet.
            const rv = handlePong(r);
            return if (rv <= 0) null else r;
        } else if (rmcp_rsp.class != rmcp_class_ipmi) {
            c.lprintf(log.Level.debug, "Invalid RMCP class: %x", @as(c_int, rmcp_rsp.class));
            rsp = recvPacket(intf);
            continue :outer;
        }

        // Note 11: the header is parsed before any length check.
        x = 4;
        r.session.authtype = r.data[@intCast(x)];
        x += 1;
        @memcpy(std.mem.asBytes(&r.session.seq), r.data[@intCast(x)..][0..4]);
        x += 4;
        @memcpy(std.mem.asBytes(&r.session.id), r.data[@intCast(x)..][0..4]);
        x += 4;

        const session = intf.session.?;

        if (r.session.id == session.session_id +% 0x10000000) {
            // With SOL the authtype is always NONE, so there is no authcode.
            r.session.payloadtype = @intCast(c.IPMI_PAYLOAD_TYPE_SOL);

            r.session.msglen = r.data[@intCast(x)];
            x += 1;

            r.payload.sol_packet.packet_sequence_number = r.data[@intCast(x)] & 0x0F;
            x += 1;

            r.payload.sol_packet.acked_packet_number = r.data[@intCast(x)] & 0x0F;
            x += 1;

            r.payload.sol_packet.accepted_character_count = r.data[@intCast(x)];
            x += 1;

            r.payload.sol_packet.is_nack = r.data[@intCast(x)] & 0x40;
            r.payload.sol_packet.transfer_unavailable = r.data[@intCast(x)] & 0x20;
            r.payload.sol_packet.sol_inactive = r.data[@intCast(x)] & 0x10;
            r.payload.sol_packet.transmit_overrun = r.data[@intCast(x)] & 0x08;
            r.payload.sol_packet.break_detected = r.data[@intCast(x)] & 0x04;
            x += 1;

            // On ISOL there is an additional fifth byte before the data.
            x += 1;

            solDebug(r);
        } else {
            // Standard IPMI 1.5 packet.
            r.session.payloadtype = @intCast(c.IPMI_PAYLOAD_TYPE_IPMI);
            if (session.active != 0 and (r.session.authtype != 0 or session.authtype != 0)) {
                x += 16;
            }

            r.session.msglen = r.data[@intCast(x)];
            x += 1;
            r.payload.ipmi_response.rq_addr = r.data[@intCast(x)];
            x += 1;
            r.payload.ipmi_response.netfn = r.data[@intCast(x)] >> 2;
            r.payload.ipmi_response.rq_lun = r.data[@intCast(x)] & 0x3;
            x += 1;
            // Checksum.
            x += 1;
            r.payload.ipmi_response.rs_addr = r.data[@intCast(x)];
            x += 1;
            r.payload.ipmi_response.rq_seq = r.data[@intCast(x)] >> 2;
            r.payload.ipmi_response.rs_lun = r.data[@intCast(x)] & 0x3;
            x += 1;
            r.payload.ipmi_response.cmd = r.data[@intCast(x)];
            x += 1;
            r.ccode = r.data[@intCast(x)];
            x += 1;

            if (c.verbose > 2) c.printbuf(&r.data, r.data_len, "ipmi message header");

            responseDebug(r);

            // Now see if we have an outstanding entry in the request list.
            const entry = reqLookupEntry(
                r.payload.ipmi_response.rq_seq,
                r.payload.ipmi_response.cmd,
            );
            if (entry) |e| {
                c.lprintf(log.Level.debug + 2, "IPMI Request Match found");
                if (intf.target_addr != @as(u32, our_address) and bridge_possible != 0) {
                    if (r.data_len != 0 and r.payload.ipmi_response.netfn == 7 and
                        r.payload.ipmi_response.cmd != 0x34)
                    {
                        if (c.verbose > 2) {
                            c.printbuf(
                                r.data[@intCast(x)..].ptr,
                                r.data_len - x,
                                "bridge command response",
                            );
                        }
                    }
                    // Bridged command: lose the extra header.
                    if (e.bridging_level != 0 and r.payload.ipmi_response.netfn == 7 and
                        r.payload.ipmi_response.cmd == 0x34)
                    {
                        e.bridging_level -= 1;
                        if (r.data_len - x - 1 == 0) {
                            rsp = if (r.ccode == 0) recvPacket(intf) else null;
                            if (e.bridging_level == 0) e.req.msg.cmd = e.req.msg.target_cmd;
                            if (rsp == null) {
                                reqRemoveEntry(e.rq_seq, e.req.msg.cmd);
                            }
                            continue :outer;
                        } else {
                            // The bridged answer is inside the incoming packet.
                            const n: usize = @intCast(r.data_len - x - 1);
                            std.mem.copyForwards(
                                u8,
                                r.data[@intCast(x - 7)..][0..n],
                                r.data[@intCast(x)..][0..n],
                            );
                            r.data[@intCast(x - 8)] -%= 8;
                            r.data_len -= 8;
                            e.rq_seq = r.data[@intCast(x - 3)] >> 2;
                            if (e.bridging_level == 0) e.req.msg.cmd = e.req.msg.target_cmd;
                            continue :outer;
                        }
                    } else {
                        if (r.data[@intCast(x - 1)] != 0) {
                            c.lprintf(
                                log.Level.debug,
                                "WARNING: Bridged cmd ccode = 0x%02x",
                                @as(c_int, r.data[@intCast(x - 1)]),
                            );
                        }
                    }
                }
                reqRemoveEntry(
                    r.payload.ipmi_response.rq_seq,
                    r.payload.ipmi_response.cmd,
                );
            } else {
                c.lprintf(log.Level.info, "IPMI Request Match NOT FOUND");
                rsp = recvPacket(intf);
                continue :outer;
            }
        }

        break :outer;
    }

    // Shift the response data to the start of the array.
    if (rsp) |r| {
        if (r.data_len > x) {
            r.data_len -= x;
            if (r.session.payloadtype == c.IPMI_PAYLOAD_TYPE_IPMI) {
                // We don't want the checksum.
                r.data_len -= 1;
            }
            const n: usize = @intCast(r.data_len);
            std.mem.copyForwards(u8, r.data[0..n], r.data[@intCast(x)..][0..n]);
            @memset(r.data[n..ipmi.buf_size], 0);
        }
    }

    return rsp;
}

fn solDebug(r: *ipmi.Response) void {
    const p = &r.payload.sol_packet;
    c.lprintf(log.Level.debug, "SOL sequence number     : 0x%02x", @as(c_int, p.packet_sequence_number));
    c.lprintf(log.Level.debug, "SOL acked packet        : 0x%02x", @as(c_int, p.acked_packet_number));
    c.lprintf(log.Level.debug, "SOL accepted char count : 0x%02x", @as(c_int, p.accepted_character_count));
    c.lprintf(log.Level.debug, "SOL is nack             : %s", boolStr(p.is_nack));
    c.lprintf(log.Level.debug, "SOL xfer unavailable    : %s", boolStr(p.transfer_unavailable));
    c.lprintf(log.Level.debug, "SOL inactive            : %s", boolStr(p.sol_inactive));
    c.lprintf(log.Level.debug, "SOL transmit overrun    : %s", boolStr(p.transmit_overrun));
    c.lprintf(log.Level.debug, "SOL break detected      : %s", boolStr(p.break_detected));
}

fn boolStr(v: u8) [*:0]const u8 {
    return pick(v != 0, "true", "false");
}

/// A `?:` between two string literals, typed for a C variadic call.
fn pick(cond: bool, a: [*:0]const u8, b: [*:0]const u8) [*:0]const u8 {
    return if (cond) a else b;
}

fn responseDebug(r: *ipmi.Response) void {
    c.lprintf(log.Level.debug + 1, "<< IPMI Response Session Header");
    c.lprintf(
        log.Level.debug + 1,
        "<<   Authtype   : %s",
        c.val2str(r.session.authtype, c.ipmi_authtype_session_vals),
    );
    c.lprintf(log.Level.debug + 1, "<<   Sequence   : 0x%08lx", @as(c_long, r.session.seq));
    c.lprintf(log.Level.debug + 1, "<<   Session ID : 0x%08lx", @as(c_long, r.session.id));
    c.lprintf(log.Level.debug + 1, "<< IPMI Response Message Header");
    const p = &r.payload.ipmi_response;
    c.lprintf(log.Level.debug + 1, "<<   Rq Addr    : %02x", @as(c_int, p.rq_addr));
    c.lprintf(log.Level.debug + 1, "<<   NetFn      : %02x", @as(c_int, p.netfn));
    c.lprintf(log.Level.debug + 1, "<<   Rq LUN     : %01x", @as(c_int, p.rq_lun));
    c.lprintf(log.Level.debug + 1, "<<   Rs Addr    : %02x", @as(c_int, p.rs_addr));
    c.lprintf(log.Level.debug + 1, "<<   Rq Seq     : %02x", @as(c_int, p.rq_seq));
    c.lprintf(log.Level.debug + 1, "<<   Rs Lun     : %01x", @as(c_int, p.rs_lun));
    c.lprintf(log.Level.debug + 1, "<<   Command    : %02x", @as(c_int, p.cmd));
    c.lprintf(log.Level.debug + 1, "<<   Compl Code : 0x%02x", @as(c_int, r.ccode));
}

// ---------------------------------------------------------------------------
// Send path
// ---------------------------------------------------------------------------

/// The `static int curr_seq` inside `ipmi_lan_build_cmd()`.
var curr_seq: c_int = 0;

fn buildCmd(intf: *Intf, req: *ipmi.Request, is_retry: c_int) ?*Entry {
    const rmcp: RmcpHdr = .{
        .ver = rmcp_version_1,
        .__reserved = 0,
        .seq = 0xff,
        .class = rmcp_class_ipmi,
    };
    var cs: c_int = 0;
    var mp: c_int = 0;
    var tmp: c_int = 0;
    var ap: c_int = 0;
    var len: c_int = 0;
    var cs2: c_int = 0;
    var cs3: c_int = 0;
    const s = intf.session.?;
    var our_address: u8 = @truncate(intf.my_addr);

    if (our_address == 0) our_address = ipmi.bmc_slave_addr;

    if (is_retry == 0) curr_seq += 1;

    if (curr_seq >= 64) curr_seq = 0;

    // Upstream comment: a bug where the same command/seq pair kept being added
    // to the lookup list.  The sequence number is not changed on a retry, so
    // the existing node is reused and only its `msg_data` is dropped.
    var entry: *Entry = undefined;
    if (reqLookupEntry(@intCast(curr_seq), req.msg.cmd)) |found| {
        entry = found;
        if (found.msg_data) |d| {
            c.free(d);
            found.msg_data = null;
        }
    } else {
        entry = reqAddEntry(intf, req, @intCast(curr_seq)) orelse return null;
    }

    len = @as(c_int, req.msg.data_len) + 29;
    if (s.active != 0 and s.authtype != 0) len += 16;
    if (intf.transit_addr != intf.my_addr and intf.transit_addr != 0) len += 8;
    const msg: [*]u8 = @ptrCast(c.malloc(@intCast(len)) orelse {
        // Note 7: the entry is already on the list at this point.
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return null;
    });
    @memset(msg[0..@intCast(len)], 0);

    // RMCP header.
    @memcpy(msg[0..@sizeOf(RmcpHdr)], std.mem.asBytes(&rmcp));
    len = @sizeOf(RmcpHdr);

    // IPMI session header.
    msg[@intCast(len)] = if (s.active != 0) s.authtype else 0;
    len += 1;

    msg[@intCast(len)] = @truncate(s.in_seq);
    len += 1;
    msg[@intCast(len)] = @truncate(s.in_seq >> 8);
    len += 1;
    msg[@intCast(len)] = @truncate(s.in_seq >> 16);
    len += 1;
    msg[@intCast(len)] = @truncate(s.in_seq >> 24);
    len += 1;
    @memcpy(msg[@intCast(len)..][0..4], std.mem.asBytes(&s.session_id));
    len += 4;

    // IPMI session authcode.
    if (s.active != 0 and s.authtype != 0) {
        ap = len;
        @memcpy(msg[@intCast(len)..][0..16], s.authcode[0..16]);
        len += 16;
    }

    // Message length.
    if (intf.target_addr == @as(u32, our_address) or bridge_possible == 0) {
        entry.bridging_level = 0;
        msg[@intCast(len)] = @truncate(req.msg.data_len +% 7);
        len += 1;
        cs = len;
        mp = len;
    } else {
        // Bridged request: encapsulate within a Send Message.
        entry.bridging_level = 1;
        const extra: u16 = if (intf.transit_addr != intf.my_addr and intf.transit_addr != 0) 8 else 0;
        msg[@intCast(len)] = @truncate(req.msg.data_len +% 15 +% extra);
        len += 1;
        cs = len;
        mp = len;
        msg[@intCast(len)] = ipmi.bmc_slave_addr;
        len += 1;
        msg[@intCast(len)] = ipmi.NetFn.app << 2;
        len += 1;
        tmp = len - cs;
        msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs)), tmp);
        len += 1;
        cs2 = len;
        msg[@intCast(len)] = ipmi.remote_swid;
        len += 1;
        msg[@intCast(len)] = @truncate(@as(c_uint, @bitCast(curr_seq)) << 2);
        len += 1;
        // Send Message request.
        msg[@intCast(len)] = 0x34;
        len += 1;
        // Save the target command and fix up the request entry.
        entry.req.msg.target_cmd = entry.req.msg.cmd;
        entry.req.msg.cmd = 0x34;

        if (intf.transit_addr == intf.my_addr or intf.transit_addr == 0) {
            // Track request.
            msg[@intCast(len)] = 0x40 | intf.target_channel;
            len += 1;
        } else {
            entry.bridging_level += 1;
            // Track request.
            msg[@intCast(len)] = 0x40 | intf.transit_channel;
            len += 1;
            cs = len;
            msg[@intCast(len)] = @truncate(intf.transit_addr);
            len += 1;
            msg[@intCast(len)] = ipmi.NetFn.app << 2;
            len += 1;
            tmp = len - cs;
            msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs)), tmp);
            len += 1;
            cs3 = len;
            msg[@intCast(len)] = @truncate(intf.my_addr);
            len += 1;
            msg[@intCast(len)] = @truncate(@as(c_uint, @bitCast(curr_seq)) << 2);
            len += 1;
            // Send Message request.
            msg[@intCast(len)] = 0x34;
            len += 1;
            // Track request.
            msg[@intCast(len)] = 0x40 | intf.target_channel;
            len += 1;
        }
        cs = len;
    }

    // IPMI message header.
    msg[@intCast(len)] = if (entry.bridging_level != 0)
        @truncate(intf.target_addr)
    else
        ipmi.bmc_slave_addr;
    len += 1;
    msg[@intCast(len)] = @as(u8, req.msg.netfn_lun.netfn) << 2 | (req.msg.netfn_lun.lun & 3);
    len += 1;
    tmp = len - cs;
    msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs)), tmp);
    len += 1;
    cs = len;

    if (entry.bridging_level == 0) {
        msg[@intCast(len)] = ipmi.remote_swid;
        len += 1;
    } else {
        // Bridged message.
        msg[@intCast(len)] = @truncate(intf.my_addr);
        len += 1;
    }

    entry.rq_seq = @intCast(curr_seq);
    msg[@intCast(len)] = entry.rq_seq << 2;
    len += 1;
    msg[@intCast(len)] = req.msg.cmd;
    len += 1;

    requestDebug(intf, req, s, entry);

    // Message data.
    if (req.msg.data_len != 0) {
        @memcpy(msg[@intCast(len)..][0..req.msg.data_len], req.msg.data.?[0..req.msg.data_len]);
        len += @as(c_int, req.msg.data_len);
    }

    // Second checksum.
    tmp = len - cs;
    msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs)), tmp);
    len += 1;

    // Bridged request: the outer checksums.
    if (entry.bridging_level != 0) {
        if (intf.transit_addr != intf.my_addr and intf.transit_addr != 0) {
            tmp = len - cs3;
            msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs3)), tmp);
            len += 1;
        }
        tmp = len - cs2;
        msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs2)), tmp);
        len += 1;
    }

    if (s.active != 0) {
        // `s->authcode` is already at `msg+ap`, but some authtypes need parts
        // of the IPMI message to build the authcode, so they are done last.
        const body = msg + @as(usize, @intCast(mp));
        const body_len: c_int = msg[@intCast(mp - 1)];
        switch (s.authtype) {
            c.IPMI_SESSION_AUTHTYPE_MD5 => {
                const temp = c.ipmi_auth_md5(@ptrCast(s), body, body_len);
                @memcpy(msg[@intCast(ap)..][0..16], temp[0..16]);
            },
            c.IPMI_SESSION_AUTHTYPE_MD2 => {
                const temp = c.ipmi_auth_md2(@ptrCast(s), body, body_len);
                @memcpy(msg[@intCast(ap)..][0..16], temp[0..16]);
            },
            else => {},
        }
    }

    // Note 8: only advanced when already non-zero.
    if (s.in_seq != 0) {
        s.in_seq +%= 1;
        if (s.in_seq == 0) s.in_seq +%= 1;
    }

    entry.msg_len = len;
    entry.msg_data = msg;

    return entry;
}

fn requestDebug(intf: *Intf, req: *ipmi.Request, s: *Session, entry: *Entry) void {
    c.lprintf(
        log.Level.debug + 1,
        ">> IPMI Request Session Header (level %d)",
        entry.bridging_level,
    );
    c.lprintf(
        log.Level.debug + 1,
        ">>   Authtype   : %s",
        c.val2str(s.authtype, c.ipmi_authtype_session_vals),
    );
    c.lprintf(log.Level.debug + 1, ">>   Sequence   : 0x%08lx", @as(c_long, s.in_seq));
    c.lprintf(log.Level.debug + 1, ">>   Session ID : 0x%08lx", @as(c_long, s.session_id));
    c.lprintf(log.Level.debug + 1, ">> IPMI Request Message Header");
    c.lprintf(log.Level.debug + 1, ">>   Rs Addr    : %02x", intf.target_addr);
    c.lprintf(log.Level.debug + 1, ">>   NetFn      : %02x", @as(c_int, req.msg.netfn_lun.netfn));
    c.lprintf(log.Level.debug + 1, ">>   Rs LUN     : %01x", @as(c_int, 0));
    c.lprintf(log.Level.debug + 1, ">>   Rq Addr    : %02x", @as(c_int, ipmi.remote_swid));
    c.lprintf(log.Level.debug + 1, ">>   Rq Seq     : %02x", @as(c_int, entry.rq_seq));
    c.lprintf(log.Level.debug + 1, ">>   Rq Lun     : %01x", @as(c_int, 0));
    c.lprintf(log.Level.debug + 1, ">>   Command    : %02x", @as(c_int, req.msg.cmd));
}

fn sendCmd(intf: *Intf, req: *ipmi.Request) callconv(.c) ?*ipmi.Response {
    var rsp: ?*ipmi.Response = null;
    var tries: c_int = 0;
    var is_retry: c_int = 0;

    c.lprintf(
        log.Level.debug,
        "ipmi_lan_send_cmd:opened=[%d], open=[%d]",
        intf.opened,
        intf.open,
    );

    if (intf.opened == 0 and intf.open != null) {
        if (intf.open.?(intf) < 0) {
            c.lprintf(log.Level.debug, "Failed to open LAN interface");
            return null;
        }
        c.lprintf(log.Level.debug, "\topened=[%d], open=[%d]", intf.opened, intf.open);
    }

    while (true) {
        is_retry = if (tries > 0) 1 else 0;

        const entry = buildCmd(intf, req, is_retry) orelse {
            c.lprintf(log.Level.err, "Aborting send command, unable to build");
            return null;
        };

        if (sendPacket(intf, entry.msg_data.?, entry.msg_len) < 0) {
            tries += 1;
            _ = c.usleep(5000);
            // Note 5: the entry was filed under `cmd`, not `target_cmd`.
            reqRemoveEntry(entry.rq_seq, entry.req.msg.target_cmd);
            continue;
        }

        // If we are set to noanswer we do not expect a response.
        if (intf.noanswer != 0) break;

        if (c.ipmi_oem_active(@ptrCast(intf), "intelwv2") != 0) thump(intf);

        _ = c.usleep(100);

        rsp = pollRecv(intf);

        // A Duplicate Request completion code most likely indicates a response
        // to a previous retry.  Ignore it and keep polling.
        if (rsp != null and rsp.?.ccode == 0xcf) {
            rsp = null;
            rsp = pollRecv(intf);
        }

        if (rsp != null) break;

        _ = c.usleep(5000);
        tries += 1;
        if (tries >= intf.ssn_params.retry) {
            c.lprintf(log.Level.debug, "  No response from remote controller");
            break;
        }
    }

    // The list has to be cleared, or a very slow controller's answer to an
    // abandoned request matches the next command's entry and is reported as
    // that command's success.
    reqClearEntries();

    return rsp;
}

// ---------------------------------------------------------------------------
// SOL
// ---------------------------------------------------------------------------

fn buildSolMsg(intf: *Intf, payload: *ipmi.V2Payload, llen: *c_int) callconv(.c) ?[*]u8 {
    const rmcp: RmcpHdr = .{
        .ver = rmcp_version_1,
        .__reserved = 0,
        .seq = 0xff,
        .class = rmcp_class_ipmi,
    };
    const session = intf.session.?;

    var len: c_int = 0;

    len = @sizeOf(RmcpHdr) // RMCP header
        + 10 // IPMI session header
        + 5 // SOL header
        + @as(c_int, payload.payload.sol_packet.character_count);

    const msg: [*]u8 = @ptrCast(c.malloc(@intCast(len)) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return null;
    });
    @memset(msg[0..@intCast(len)], 0);

    // RMCP header.
    @memcpy(msg[0..@sizeOf(RmcpHdr)], std.mem.asBytes(&rmcp));
    len = @sizeOf(RmcpHdr);

    // IPMI session header.  SOL is always authtype NONE.
    msg[@intCast(len)] = 0;
    len += 1;
    msg[@intCast(len)] = @truncate(session.in_seq);
    len += 1;
    msg[@intCast(len)] = @truncate(session.in_seq >> 8);
    len += 1;
    msg[@intCast(len)] = @truncate(session.in_seq >> 16);
    len += 1;
    msg[@intCast(len)] = @truncate(session.in_seq >> 24);
    len += 1;

    msg[@intCast(len)] = @truncate(session.session_id);
    len += 1;
    msg[@intCast(len)] = @truncate(session.session_id >> 8);
    len += 1;
    msg[@intCast(len)] = @truncate(session.session_id >> 16);
    len += 1;
    // Add 0x10 to the MSB for SOL.
    msg[@intCast(len)] = @truncate((session.session_id >> 24) +% 0x10);
    len += 1;

    const sol = &payload.payload.sol_packet;

    msg[@intCast(len)] = @truncate(sol.character_count +% 5);
    len += 1;

    // SOL header.
    msg[@intCast(len)] = sol.packet_sequence_number;
    len += 1;
    msg[@intCast(len)] = sol.acked_packet_number;
    len += 1;
    msg[@intCast(len)] = sol.accepted_character_count;
    len += 1;
    msg[@intCast(len)] = if (sol.is_nack != 0) 0x40 else 0;
    msg[@intCast(len)] |= if (sol.assert_ring_wor != 0) 0x20 else 0;
    msg[@intCast(len)] |= if (sol.generate_break != 0) 0x10 else 0;
    msg[@intCast(len)] |= if (sol.deassert_cts != 0) 0x08 else 0;
    msg[@intCast(len)] |= if (sol.deassert_dcd_dsr != 0) 0x04 else 0;
    msg[@intCast(len)] |= if (sol.flush_inbound != 0) 0x02 else 0;
    msg[@intCast(len)] |= if (sol.flush_outbound != 0) 0x01 else 0;
    len += 1;

    // On SOL there is an additional fifth byte before the data.
    len += 1;

    if (sol.character_count != 0) {
        @memcpy(
            msg[@intCast(len)..][0..sol.character_count],
            sol.data[0..sol.character_count],
        );
        len += @as(c_int, sol.character_count);
    }

    session.in_seq +%= 1;
    if (session.in_seq == 0) session.in_seq +%= 1;

    llen.* = len;
    return msg;
}

fn isSolPacket(rsp: ?*ipmi.Response) bool {
    const r = rsp orelse return false;
    return r.session.payloadtype == c.IPMI_PAYLOAD_TYPE_SOL;
}

fn solResponseAcksPacket(rsp: ?*ipmi.Response, payload: ?*ipmi.V2Payload) bool {
    if (!isSolPacket(rsp)) return false;
    const p = payload orelse return false;
    return p.payload_type == c.IPMI_PAYLOAD_TYPE_SOL and
        rsp.?.payload.sol_packet.acked_packet_number ==
            p.payload.sol_packet.packet_sequence_number;
}

fn sendSolPayload(intf: *Intf, payload: *ipmi.V2Payload) ?*ipmi.Response {
    var rsp: ?*ipmi.Response = null;
    var len: c_int = 0;
    var tries: c_int = 0;

    if (intf.opened == 0 and intf.open != null) {
        if (intf.open.?(intf) < 0) return null;
    }

    const msg = buildSolMsg(intf, payload, &len);
    if (len <= 0 or msg == null) {
        c.lprintf(log.Level.err, "Invalid SOL payload packet");
        if (msg) |m| c.free(m);
        return null;
    }

    c.lprintf(log.Level.debug, ">> SENDING A SOL MESSAGE\n");

    while (true) {
        if (sendPacket(intf, msg.?, len) < 0) {
            tries += 1;
            _ = c.usleep(5000);
            continue;
        }

        // If we are set to noanswer we do not expect a response.
        if (intf.noanswer != 0) break;

        if (payload.payload.sol_packet.packet_sequence_number == 0) {
            // Just an ACK; no need to retry.
            break;
        }

        _ = c.usleep(100);

        // Grab the next packet.
        rsp = recvSol(intf);

        if (solResponseAcksPacket(rsp, payload)) {
            break;
        } else if (isSolPacket(rsp) and rsp.?.data_len != 0) {
            // Still waiting for the ACK, but there is more data from the BMC.
            intf.session.?.sol_data.sol_input_handler.?(rsp);
        }

        _ = c.usleep(5000);
        tries += 1;
        if (tries >= intf.ssn_params.retry) {
            c.lprintf(log.Level.debug, "  No response from remote controller");
            break;
        }
    }

    c.free(msg.?);
    return rsp;
}

/// How many characters have to be resent after a partial ACK/NACK.
fn isSolPartialAck(v2_payload: ?*ipmi.V2Payload, rsp: ?*ipmi.Response) c_int {
    var chars_to_resend: c_int = 0;

    if (v2_payload != null and rsp != null and isSolPacket(rsp) and
        solResponseAcksPacket(rsp, v2_payload) and
        rsp.?.payload.sol_packet.accepted_character_count <
            v2_payload.?.payload.sol_packet.character_count)
    {
        if (rsp.?.payload.sol_packet.accepted_character_count == 0) {
            // We should not resend data.
            chars_to_resend = 0;
        } else {
            chars_to_resend = @as(c_int, v2_payload.?.payload.sol_packet.character_count) -
                @as(c_int, rsp.?.payload.sol_packet.accepted_character_count);
        }
    }

    return chars_to_resend;
}

fn setSolPacketSequenceNumber(intf: *Intf, v2_payload: *ipmi.V2Payload) void {
    const sol = &intf.session.?.sol_data;
    // Keep our sequence number sane.
    if (sol.sequence_number > 0x0F) sol.sequence_number = 1;

    v2_payload.payload.sol_packet.packet_sequence_number = sol.sequence_number;
    sol.sequence_number +%= 1;
}

fn sendSol(intf: *Intf, v2_payload: *ipmi.V2Payload) callconv(.c) ?*ipmi.Response {
    v2_payload.payload_type = @intCast(c.IPMI_PAYLOAD_TYPE_SOL);

    // The payload length here is just the length of the character data.
    v2_payload.payload.sol_packet.acked_packet_number = 0;

    setSolPacketSequenceNumber(intf, v2_payload);

    v2_payload.payload.sol_packet.accepted_character_count = 0;

    var rsp = sendSolPayload(intf, v2_payload);

    var chars_to_resend = isSolPartialAck(v2_payload, rsp);

    while (chars_to_resend != 0) {
        // Any new data that arrived in the NACK is handled first.
        if (rsp.?.data_len != 0) intf.session.?.sol_data.sol_input_handler.?(rsp);

        setSolPacketSequenceNumber(intf, v2_payload);

        // Just send the required data.
        const accepted: usize = rsp.?.payload.sol_packet.accepted_character_count;
        const n: usize = @intCast(chars_to_resend);
        const data = &v2_payload.payload.sol_packet.data;
        std.mem.copyForwards(u8, data[0..n], data[accepted..][0..n]);

        v2_payload.payload.sol_packet.character_count = @intCast(chars_to_resend);

        rsp = sendSolPayload(intf, v2_payload);

        chars_to_resend = isSolPartialAck(v2_payload, rsp);
    }

    return rsp;
}

/// The two `static` counters inside `check_sol_packet_for_new_data()`.
var last_received_sequence_number: u8 = 0;
var last_received_byte_count: u8 = 0;

fn checkSolPacketForNewData(rsp: ?*ipmi.Response) c_int {
    var new_data_size: c_int = 0;

    if (rsp) |r| {
        if (r.session.payloadtype == c.IPMI_PAYLOAD_TYPE_SOL) {
            const unaltered_data_len: u8 = @truncate(@as(c_uint, @bitCast(r.data_len)));
            if (r.payload.sol_packet.packet_sequence_number ==
                last_received_sequence_number)
            {
                // The same as the last packet, but it may include extra data.
                new_data_size = r.data_len - last_received_byte_count;

                if (new_data_size > 0) {
                    const n: usize = @intCast(new_data_size);
                    const from: usize = @intCast(r.data_len - new_data_size);
                    std.mem.copyForwards(u8, r.data[0..n], r.data[from..][0..n]);
                }

                r.data_len = new_data_size;
            }

            // Remember the data for the next round.
            if (r.payload.sol_packet.packet_sequence_number != 0) {
                last_received_sequence_number = r.payload.sol_packet.packet_sequence_number;
                last_received_byte_count = unaltered_data_len;
            }
        }
    }

    return new_data_size;
}

fn ackSolPacket(intf: *Intf, rsp: ?*ipmi.Response) void {
    const r = rsp orelse return;
    if (r.session.payloadtype != c.IPMI_PAYLOAD_TYPE_SOL) return;
    if (r.payload.sol_packet.packet_sequence_number == 0) return;

    var ack: ipmi.V2Payload = std.mem.zeroes(ipmi.V2Payload);

    ack.payload_type = @intCast(c.IPMI_PAYLOAD_TYPE_SOL);

    // The payload length here is just the length of the character data.
    ack.payload_length = 0;

    // ACK packets have a sequence number of 0.
    ack.payload.sol_packet.packet_sequence_number = 0;

    ack.payload.sol_packet.acked_packet_number = r.payload.sol_packet.packet_sequence_number;

    ack.payload.sol_packet.accepted_character_count = @truncate(@as(c_uint, @bitCast(r.data_len)));

    _ = sendSolPayload(intf, &ack);
}

fn recvSol(intf: *Intf) callconv(.c) ?*ipmi.Response {
    const rsp = pollRecv(intf);

    ackSolPacket(intf, rsp);

    // Remembers the data sent, and alters the data to just the new part.
    _ = checkSolPacketForNewData(rsp);

    return rsp;
}

// ---------------------------------------------------------------------------
// Session setup
// ---------------------------------------------------------------------------

/// Send a Get Device ID command to keep the session active.
fn keepalive(intf: *Intf) callconv(.c) c_int {
    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app;
    req.msg.cmd = 1;

    if (intf.opened == 0) return 0;

    const rsp = intf.sendrecv.?(intf, &req);
    if (rsp == null or rsp.?.ccode != 0) return -1;

    return 0;
}

fn getAuthCapabilitiesCmd(intf: *Intf) c_int {
    const s = intf.session.?;
    const p = &intf.ssn_params;
    var msg_data: [2]u8 = undefined;

    msg_data[0] = lan_channel_e;
    msg_data[1] = p.privlvl;

    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app;
    req.msg.cmd = 0x38;
    req.msg.data = &msg_data;
    req.msg.data_len = 2;

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(log.Level.info, "Get Auth Capabilities command failed");
        return -1;
    };
    if (c.verbose > 2) c.printbuf(&rsp.data, rsp.data_len, "get_auth_capabilities");

    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.info,
            "Get Auth Capabilities command failed: %s",
            c.val2str(rsp.ccode, c.completion_code_vals),
        );
        return -1;
    }

    authCapabilitiesDebug(&req, rsp);

    s.authstatus = rsp.data[2];

    const types = rsp.data[1];

    if (p.password != 0 and
        (p.authtype_set == 0 or p.authtype_set == c.IPMI_SESSION_AUTHTYPE_MD5) and
        authTypeBit(types, c.IPMI_SESSION_AUTHTYPE_MD5))
    {
        s.authtype = c.IPMI_SESSION_AUTHTYPE_MD5;
    } else if (p.password != 0 and
        (p.authtype_set == 0 or p.authtype_set == c.IPMI_SESSION_AUTHTYPE_MD2) and
        authTypeBit(types, c.IPMI_SESSION_AUTHTYPE_MD2))
    {
        s.authtype = c.IPMI_SESSION_AUTHTYPE_MD2;
    } else if (p.password != 0 and
        (p.authtype_set == 0 or p.authtype_set == c.IPMI_SESSION_AUTHTYPE_PASSWORD) and
        authTypeBit(types, c.IPMI_SESSION_AUTHTYPE_PASSWORD))
    {
        s.authtype = c.IPMI_SESSION_AUTHTYPE_PASSWORD;
    } else if (p.password != 0 and
        (p.authtype_set == 0 or p.authtype_set == c.IPMI_SESSION_AUTHTYPE_OEM) and
        authTypeBit(types, c.IPMI_SESSION_AUTHTYPE_OEM))
    {
        s.authtype = c.IPMI_SESSION_AUTHTYPE_OEM;
    } else if ((p.authtype_set == 0 or p.authtype_set == c.IPMI_SESSION_AUTHTYPE_NONE) and
        authTypeBit(types, c.IPMI_SESSION_AUTHTYPE_NONE))
    {
        s.authtype = c.IPMI_SESSION_AUTHTYPE_NONE;
    } else {
        if (!authTypeBit(types, p.authtype_set)) {
            c.lprintf(
                log.Level.err,
                "Authentication type %s not supported",
                c.val2str(p.authtype_set, c.ipmi_authtype_session_vals),
            );
        } else {
            c.lprintf(log.Level.err, "No supported authtypes found");
        }

        return -1;
    }

    c.lprintf(
        log.Level.debug,
        "Proceeding with AuthType %s",
        c.val2str(s.authtype, c.ipmi_authtype_session_vals),
    );

    return 0;
}

/// `rsp->data[1] & 1<<t`.  `1` is an `int` in C, so the shift happens in 32
/// bits; `authtype_set` is only ever 0..5 in practice.
fn authTypeBit(bits: u8, t: u8) bool {
    return (@as(u32, bits) & (@as(u32, 1) << @truncate(t))) != 0;
}

fn authCapabilitiesDebug(req: *ipmi.Request, rsp: *ipmi.Response) void {
    c.lprintf(log.Level.debug, "Channel %02x Authentication Capabilities:", @as(c_int, rsp.data[0]));
    c.lprintf(
        log.Level.debug,
        "  Privilege Level : %s",
        c.val2str(req.msg.data.?[1], c.ipmi_privlvl_vals),
    );
    c.lprintf(
        log.Level.debug,
        "  Auth Types      : %s%s%s%s%s",
        pick((rsp.data[1] & 1 << c.IPMI_SESSION_AUTHTYPE_NONE) != 0, "NONE ", ""),
        pick((rsp.data[1] & 1 << c.IPMI_SESSION_AUTHTYPE_MD2) != 0, "MD2 ", ""),
        pick((rsp.data[1] & 1 << c.IPMI_SESSION_AUTHTYPE_MD5) != 0, "MD5 ", ""),
        pick((rsp.data[1] & 1 << c.IPMI_SESSION_AUTHTYPE_PASSWORD) != 0, "PASSWORD ", ""),
        pick((rsp.data[1] & 1 << c.IPMI_SESSION_AUTHTYPE_OEM) != 0, "OEM ", ""),
    );
    c.lprintf(
        log.Level.debug,
        "  Per-msg auth    : %sabled",
        pick((rsp.data[2] & c.IPMI_AUTHSTATUS_PER_MSG_DISABLED) != 0, "dis", "en"),
    );
    c.lprintf(
        log.Level.debug,
        "  User level auth : %sabled",
        pick((rsp.data[2] & c.IPMI_AUTHSTATUS_PER_USER_DISABLED) != 0, "dis", "en"),
    );
    c.lprintf(
        log.Level.debug,
        "  Non-null users  : %sabled",
        pick((rsp.data[2] & c.IPMI_AUTHSTATUS_NONNULL_USERS_ENABLED) != 0, "en", "dis"),
    );
    c.lprintf(
        log.Level.debug,
        "  Null users      : %sabled",
        pick((rsp.data[2] & c.IPMI_AUTHSTATUS_NULL_USERS_ENABLED) != 0, "en", "dis"),
    );
    c.lprintf(
        log.Level.debug,
        "  Anonymous login : %sabled",
        pick((rsp.data[2] & c.IPMI_AUTHSTATUS_ANONYMOUS_USERS_ENABLED) != 0, "en", "dis"),
    );
    c.lprintf(log.Level.debug, "");
}

/// Get Session Challenge: returns a temporary session id and a 16 byte
/// challenge string.
fn getSessionChallengeCmd(intf: *Intf) c_int {
    const s = intf.session.?;
    var msg_data: [17]u8 = @splat(0);

    msg_data[0] = s.authtype;
    @memcpy(msg_data[1..17], intf.ssn_params.username[0..16]);

    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app;
    req.msg.cmd = 0x39;
    req.msg.data = &msg_data;
    // One byte for the authtype, sixteen for the user.
    req.msg.data_len = 17;

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(log.Level.err, "Get Session Challenge command failed");
        return -1;
    };
    if (c.verbose > 2) c.printbuf(&rsp.data, rsp.data_len, "get_session_challenge");

    if (rsp.ccode != 0) {
        switch (rsp.ccode) {
            0x81 => c.lprintf(log.Level.err, "Invalid user name"),
            0x82 => c.lprintf(log.Level.err, "NULL user name not enabled"),
            else => c.lprintf(
                log.Level.err,
                "Get Session Challenge command failed: %s",
                c.val2str(rsp.ccode, c.completion_code_vals),
            ),
        }
        return -1;
    }

    @memcpy(std.mem.asBytes(&s.session_id), rsp.data[0..4]);
    @memcpy(s.challenge[0..16], rsp.data[4..20]);

    c.lprintf(log.Level.debug, "Opening Session");
    c.lprintf(log.Level.debug, "  Session ID      : %08lx", @as(c_long, s.session_id));
    c.lprintf(log.Level.debug, "  Challenge       : %s", c.buf2str(&s.challenge, 16));

    return 0;
}

fn activateSessionCmd(intf: *Intf) c_int {
    const s = intf.session.?;
    var msg_data: [22]u8 = undefined;

    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app;
    req.msg.cmd = 0x3a;

    msg_data[0] = s.authtype;
    msg_data[1] = intf.ssn_params.privlvl;

    // Supermicro OEM authentication hack.
    if (c.ipmi_oem_active(@ptrCast(intf), "supermicro") != 0) {
        const special = c.ipmi_auth_special(@ptrCast(s));
        @memcpy(s.authcode[0..16], special[0..16]);
        @memset(msg_data[2..18], 0);
        c.lprintf(log.Level.debug, "  OEM Auth        : %s", c.buf2str(special, 16));
    } else {
        @memcpy(msg_data[2..18], s.challenge[0..16]);
    }

    // Set up the initial outbound sequence number.
    _ = getRandom(msg_data[18..].ptr, 4);

    req.msg.data = &msg_data;
    req.msg.data_len = 22;

    s.active = 1;

    c.lprintf(
        log.Level.debug,
        "  Privilege Level : %s",
        c.val2str(msg_data[1], c.ipmi_privlvl_vals),
    );
    c.lprintf(
        log.Level.debug,
        "  Auth Type       : %s",
        c.val2str(s.authtype, c.ipmi_authtype_session_vals),
    );

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(log.Level.err, "Activate Session command failed");
        s.active = 0;
        return -1;
    };
    if (c.verbose > 2) c.printbuf(&rsp.data, rsp.data_len, "activate_session");

    if (rsp.ccode != 0) {
        _ = c.fprintf(c.stderr, "Activate Session error:");
        switch (rsp.ccode) {
            0x81 => c.lprintf(log.Level.err, "\tNo session slot available"),
            0x82 => c.lprintf(
                log.Level.err,
                "\tNo slot available for given user - limit reached",
            ),
            0x83 => c.lprintf(
                log.Level.err,
                "\tNo slot available to support user due to maximum privilege capacity",
            ),
            0x84 => c.lprintf(log.Level.err, "\tSession sequence out of range"),
            0x85 => c.lprintf(log.Level.err, "\tInvalid session ID in request"),
            0x86 => c.lprintf(log.Level.err, "\tRequested privilege level exceeds limit"),
            0xd4 => c.lprintf(log.Level.err, "\tInsufficient privilege level"),
            else => c.lprintf(
                log.Level.err,
                "\t%s",
                c.val2str(rsp.ccode, c.completion_code_vals),
            ),
        }
        return -1;
    }

    @memcpy(std.mem.asBytes(&s.session_id), rsp.data[1..5]);
    s.in_seq = @as(u32, rsp.data[8]) << 24 | @as(u32, rsp.data[7]) << 16 |
        @as(u32, rsp.data[6]) << 8 | @as(u32, rsp.data[5]);
    if (s.in_seq == 0) s.in_seq +%= 1;

    if ((s.authstatus & c.IPMI_AUTHSTATUS_PER_MSG_DISABLED) != 0) {
        s.authtype = c.IPMI_SESSION_AUTHTYPE_NONE;
    } else if (s.authtype != (rsp.data[0] & 0xf)) {
        c.lprintf(
            log.Level.err,
            "Invalid Session AuthType %s in response",
            c.val2str(s.authtype, c.ipmi_authtype_session_vals),
        );
        return -1;
    }

    c.lprintf(log.Level.debug, "\nSession Activated");
    c.lprintf(
        log.Level.debug,
        "  Auth Type       : %s",
        c.val2str(rsp.data[0], c.ipmi_authtype_session_vals),
    );
    c.lprintf(
        log.Level.debug,
        "  Max Priv Level  : %s",
        c.val2str(rsp.data[9], c.ipmi_privlvl_vals),
    );
    c.lprintf(log.Level.debug, "  Session ID      : %08lx", @as(c_long, s.session_id));
    c.lprintf(log.Level.debug, "  Inbound Seq     : %08lx\n", @as(c_long, s.in_seq));

    return 0;
}

fn setSessionPrivlvlCmd(intf: *Intf) c_int {
    var privlvl: u8 = intf.ssn_params.privlvl;
    const backup_bridge_possible = bridge_possible;

    // No need to set a higher level.
    if (privlvl <= c.IPMI_SESSION_PRIV_USER) return 0;

    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app;
    req.msg.cmd = 0x3b;
    req.msg.data = @ptrCast(&privlvl);
    req.msg.data_len = 1;

    bridge_possible = 0;
    const rsp = intf.sendrecv.?(intf, &req);
    bridge_possible = backup_bridge_possible;

    if (rsp == null) {
        c.lprintf(
            log.Level.err,
            "Set Session Privilege Level to %s failed",
            c.val2str(privlvl, c.ipmi_privlvl_vals),
        );
        return -1;
    }
    if (c.verbose > 2) c.printbuf(&rsp.?.data, rsp.?.data_len, "set_session_privlvl");

    if (rsp.?.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Set Session Privilege Level to %s failed: %s",
            c.val2str(privlvl, c.ipmi_privlvl_vals),
            c.val2str(rsp.?.ccode, c.completion_code_vals),
        );
        return -1;
    }

    c.lprintf(
        log.Level.debug,
        "Set Session Privilege Level to %s\n",
        c.val2str(rsp.?.data[0], c.ipmi_privlvl_vals),
    );

    return 0;
}

fn closeSessionCmd(intf: *Intf) c_int {
    var msg_data: [4]u8 = undefined;
    const session_id = intf.session.?.session_id;

    if (intf.session.?.active == 0) return -1;

    intf.target_addr = ipmi.bmc_slave_addr;
    // Not a bridge message.
    bridge_possible = 0;

    @memcpy(&msg_data, std.mem.asBytes(&session_id));

    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app;
    req.msg.cmd = 0x3c;
    req.msg.data = &msg_data;
    req.msg.data_len = 4;

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(log.Level.err, "Close Session command failed");
        return -1;
    };
    if (c.verbose > 2) c.printbuf(&rsp.data, rsp.data_len, "close_session");

    if (rsp.ccode == 0x87) {
        c.lprintf(
            log.Level.err,
            "Failed to Close Session: invalid session ID %08lx",
            @as(c_long, session_id),
        );
        return -1;
    }
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Close Session command failed: %s",
            c.val2str(rsp.ccode, c.completion_code_vals),
        );
        return -1;
    }

    c.lprintf(log.Level.debug, "Closed Session %08lx\n", @as(c_long, session_id));

    return 0;
}

/// IPMI LAN session activation, IPMI spec v1.5 section 12.9.
fn activateSession(intf: *Intf) c_int {
    // Don't fail on the ping, it is not always supported: Supermicro's IPMI
    // LAN 1.5 cards don't tolerate them.
    if (c.ipmi_oem_active(@ptrCast(intf), "supermicro") == 0) _ = lanPing(intf);

    // Some Intel boards need special help.
    if (c.ipmi_oem_active(@ptrCast(intf), "intelwv2") != 0) thumpFirst(intf);

    if (getAuthCapabilitiesCmd(intf) < 0) return activateFail();

    if (getSessionChallengeCmd(intf) < 0) return activateFail();

    if (activateSessionCmd(intf) < 0) return activateFail();

    intf.abort = 0;

    if (setSessionPrivlvlCmd(intf) < 0) {
        _ = closeSessionCmd(intf);
        return activateFail();
    }

    return 0;
}

fn activateFail() c_int {
    c.lprintf(log.Level.err, "Error: Unable to establish LAN session");
    return -1;
}

fn close(intf: *Intf) callconv(.c) void {
    if (intf.abort == 0 and intf.session != null) _ = closeSessionCmd(intf);

    if (intf.fd >= 0) {
        _ = c.close(intf.fd);
        intf.fd = -1;
    }

    reqClearEntries();
    c.ipmi_intf_session_cleanup(@ptrCast(intf));
    intf.opened = 0;
    intf.manufacturer_id = @enumFromInt(c.IPMI_OEM_UNKNOWN);
    // Note 9: upstream assigns NULL to its own parameter here.
}

fn open(intf: *Intf) callconv(.c) c_int {
    // Note 12: the `!intf` half of the upstream guard has no counterpart.
    if (intf.opened != 0) return -1;

    const p = &intf.ssn_params;

    if (p.port == 0) p.port = lan_port;
    if (p.privlvl == 0) p.privlvl = c.IPMI_SESSION_PRIV_ADMIN;
    if (p.timeout == 0) p.timeout = lan_timeout;
    if (p.retry == 0) p.retry = lan_retry;

    if (p.hostname == null or std.mem.len(p.hostname.?) == 0) {
        c.lprintf(log.Level.err, "No hostname specified!");
        return -1;
    }

    if (c.ipmi_intf_socket_connect(@ptrCast(intf)) == -1) {
        c.lprintf(log.Level.err, "Could not open socket!");
        return -1;
    }

    // Note 10: the `s` read from `intf->session` above is overwritten here.
    const s: *Session = @ptrCast(@alignCast(c.malloc(@sizeOf(Session)) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return openFail(intf);
    }));

    intf.opened = 1;
    intf.abort = 1;

    intf.session = s;

    s.* = std.mem.zeroes(Session);
    s.sol_data.sequence_number = 1;
    s.timeout = p.timeout;
    @memcpy(&s.authcode, &p.authcode_set);
    s.addrlen = @sizeOf(@TypeOf(s.addr));
    if (c.getsockname(intf.fd, @ptrCast(&s.addr), &s.addrlen) != 0) {
        return openFail(intf);
    }

    // Try to open a session.
    if (activateSession(intf) < 0) {
        return openFail(intf);
    }

    // Automatically detect the interface request and response sizes.
    _ = c.hpm2_detect_max_payload_size(@ptrCast(intf));

    // Set the manufacturer OEM id.
    intf.manufacturer_id = @enumFromInt(c.ipmi_get_oem(@ptrCast(intf)));

    // Now allow bridging.
    bridge_possible = 1;
    return intf.fd;
}

fn openFail(intf: *Intf) c_int {
    c.lprintf(log.Level.err, "Error: Unable to establish IPMI v1.5 / RMCP session");
    intf.close.?(intf);
    return -1;
}

fn setup(intf: *Intf) callconv(.c) c_int {
    // Set up the default LAN maximum request and response sizes.
    intf.max_request_data_size = max_request_size;
    intf.max_response_data_size = max_response_size;

    return 0;
}

fn setMaxRqDataSize(intf: *Intf, size: u16) callconv(.c) void {
    var s = size;
    if (@as(c_int, s) + 7 > 0xFF) s = 0xFF - 7;

    intf.max_request_data_size = s;
}

fn setMaxRpDataSize(intf: *Intf, size: u16) callconv(.c) void {
    var s = size;
    if (@as(c_int, s) + 8 > 0xFF) s = 0xFF - 8;

    intf.max_response_data_size = s;
}

/// `struct ipmi_intf ipmi_lan_intf`.
var lan_intf: Intf = blk: {
    var i: Intf = std.mem.zeroes(Intf);
    const name = "lan";
    const desc = "IPMI v1.5 LAN Interface";
    @memcpy(i.name[0..name.len], name);
    @memcpy(i.desc[0..desc.len], desc);
    i.setup = setup;
    i.open = open;
    i.close = close;
    i.sendrecv = sendCmd;
    i.recv_sol = recvSol;
    i.send_sol = sendSol;
    i.keepalive = keepalive;
    i.set_max_request_data_size = setMaxRqDataSize;
    i.set_max_response_data_size = setMaxRpDataSize;
    i.target_addr = ipmi.bmc_slave_addr;
    break :blk i;
};

// ---------------------------------------------------------------------------
// ABI parity
// ---------------------------------------------------------------------------

comptime {
    abi.assertLayout(RmcpHdr, c.struct_rmcp_hdr);
    abi.assertLayout(AsfHdr, c.struct_asf_hdr);
    abi.assertLayout(RmcpPong, c.struct_rmcp_pong);
}

pub fn exportSymbols() void {
    // `ipmi_lan_build_sol_msg` has external linkage upstream but is declared in
    // no header and called from nowhere, so there is no C prototype to check it
    // against; the export exists only to keep the symbol table identical.
    @export(&buildSolMsg, .{ .name = "ipmi_lan_build_sol_msg" });

    // Likewise `ipmi_req_entries`: external linkage, no declaration anywhere.
    // `lanplus.c` has its own `static` variable of the same name.
    @export(&req_entries, .{ .name = "ipmi_req_entries" });

    @export(&lan_intf, .{ .name = "ipmi_lan_intf" });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// These cover the parts of the transport that `tests/transport/` cannot reach
// on its own: the packet assembler's bridged forms (the model BMC speaks to a
// single target), the request-list surgery, the SOL sequence-number and
// partial-ACK arithmetic, and the size clamps.  Everything below is pure --
// no socket is opened -- so each case can state the exact bytes it expects.
//
// Every constant here follows the rule documented in `tests/transport/Bmc.zig`:
// four distinct non-zero bytes for a 32-bit field, sixteen for a blob.  Zeros
// hide short writes (the packet is assembled in a zeroed buffer) and repeats
// hide byte-order and shift mistakes.

const testing = std.testing;

comptime {
    // `val2str()` and the rest of the C the transport reaches for are supplied
    // by `intf/test_stubs.zig`, which only exists in the test binary.
    if (builtin.is_test) _ = @import("test_stubs.zig");
}

/// `session_id`, copied into the packet as raw native-endian bytes.
const t_session_id: u32 = 0x0a0b0c0d;

/// `in_seq`, written out a byte at a time with explicit shifts.
const t_in_seq: u32 = 0x51627384;

/// Sixteen distinct non-zero bytes so a short `authcode` copy is visible.
const t_authcode: [16]u8 = .{
    0x31, 0x42, 0x53, 0x64, 0x75, 0x86, 0x97, 0xa8,
    0xb9, 0xca, 0xdb, 0xec, 0xfd, 0x0e, 0x1f, 0x20,
};

const TestIntf = struct {
    intf: Intf,
    session: Session,
    req_data: [3]u8 = .{ 0x71, 0x72, 0x73 },
    req: ipmi.Request,

    fn init(self: *TestIntf) void {
        self.intf = std.mem.zeroes(Intf);
        self.session = std.mem.zeroes(Session);
        self.req_data = .{ 0x71, 0x72, 0x73 };
        self.intf.session = &self.session;
        self.intf.my_addr = ipmi.bmc_slave_addr;
        self.intf.target_addr = ipmi.bmc_slave_addr;
        self.session.session_id = t_session_id;
        self.session.in_seq = t_in_seq;
        @memcpy(self.session.authcode[0..16], &t_authcode);

        self.req = std.mem.zeroes(ipmi.Request);
        self.req.msg.netfn_lun.netfn = 0x2e;
        self.req.msg.netfn_lun.lun = 2;
        self.req.msg.cmd = 0x9b;
        self.req.msg.data = &self.req_data;
        self.req.msg.data_len = self.req_data.len;
    }
};

/// The globals `lan.c` keeps in file scope are not reset between Zig tests.
fn resetLanGlobals() void {
    reqClearEntries();
    curr_seq = 0;
    bridge_possible = 0;
    last_received_sequence_number = 0;
    last_received_byte_count = 0;
    recv_rsp = std.mem.zeroes(ipmi.Response);
}

/// A `socketpair(AF_UNIX, SOCK_DGRAM)` standing in for the UDP socket.
///
/// The real thing rather than a seam: `send_packet`, `recv_packet` and the
/// `select()` in front of it are the code under test, and a datagram socket
/// preserves exactly the message boundaries `ipmi_lan_recv_packet()` relies
/// on.  A zero `timeout` makes the empty case return at once.
const Wire = struct {
    tool: c_int,
    bmc: c_int,

    fn init() !Wire {
        var fds: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_DGRAM, 0, &fds) != 0) return error.SocketPair;
        return .{ .tool = fds[0], .bmc = fds[1] };
    }

    fn deinit(self: Wire) void {
        _ = c.close(self.tool);
        _ = c.close(self.bmc);
    }

    fn send(self: Wire, data: []const u8) !void {
        const n = c.send(self.bmc, data.ptr, data.len, 0);
        if (n != @as(isize, @intCast(data.len))) return error.ShortWrite;
    }

    fn recv(self: Wire, buf: []u8) ![]u8 {
        const n = c.recv(self.bmc, buf.ptr, buf.len, 0);
        if (n < 0) return error.RecvFailed;
        return buf[0..@intCast(n)];
    }
};

fn expectPacket(entry: *Entry, want: []const u8) !void {
    try testing.expectEqual(@as(c_int, @intCast(want.len)), entry.msg_len);
    try testing.expectEqualSlices(u8, want, entry.msg_data.?[0..want.len]);
}

test "build_cmd assembles an unbridged v1.5 packet" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();
    curr_seq = 0x11;

    const entry = buildCmd(&t.intf, &t.req, 0).?;

    // curr_seq is bumped before use, so rq_seq is 0x12 and the wire byte is
    // 0x12 << 2 == 0x48.
    try testing.expectEqual(@as(c_int, 0x12), curr_seq);
    try testing.expectEqual(@as(u8, 0x12), entry.rq_seq);
    try testing.expectEqual(@as(c_int, 0), entry.bridging_level);

    try expectPacket(entry, &.{
        0x06, 0x00, 0xff, 0x07, // rmcp: version 1, reserved, seq 0xff, class ipmi
        0x00, //                   authtype: session inactive
        0x84, 0x73, 0x62, 0x51, //  in_seq, least significant byte first
        0x0d, 0x0c, 0x0b, 0x0a, //  session id, native byte order
        0x0a, //                   message length: data_len + 7
        0x20, 0xba, 0x26, //       rs_addr, netfn<<2|lun, csum1
        0x81, 0x48, 0x9b, //       rq_addr, rq_seq<<2, cmd
        0x71, 0x72, 0x73, //       data
        0x46, //                   csum2
    });

    // Note 8: `in_seq` was already non-zero, so it advances.
    try testing.expectEqual(t_in_seq + 1, t.session.in_seq);
}

test "build_cmd inserts the authcode and hands the hook the message body" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();
    t.session.active = 1;
    t.session.authtype = c.IPMI_SESSION_AUTHTYPE_MD5;
    curr_seq = 0x11;

    // `ipmi_auth_md5` folds in `s->in_seq`, and `build_cmd` calls it before
    // advancing that, so the oracle needs the session as it was on entry.
    var before = t.session;

    const entry = buildCmd(&t.intf, &t.req, 0).?;

    // The hook is handed `msg + mp` for `msg[mp - 1]` bytes: exactly the run
    // the message-length byte counts, starting at the byte after it.  Feeding
    // the real `ipmi_auth_md5` that slice and getting the packet's authcode
    // back pins the slice, its length and where the answer is written.
    const body = [_]u8{ 0x20, 0xba, 0x26, 0x81, 0x48, 0x9b, 0x71, 0x72, 0x73, 0x46 };
    var want_authcode: [16]u8 = undefined;
    @memcpy(&want_authcode, c.ipmi_auth_md5(@ptrCast(&before), @constCast(&body), body.len)[0..16]);

    // Not the raw password: the hook really did run.
    try testing.expect(!std.mem.eql(u8, &want_authcode, &t_authcode));

    try testing.expectEqual(@as(c_int, 40), entry.msg_len);
    try testing.expectEqualSlices(u8, &.{
        0x06, 0x00, 0xff, 0x07,
        0x02, //                   authtype: MD5, because the session is active
        0x84,
        0x73,
        0x62,
        0x51,
        0x0d,
        0x0c,
        0x0b,
        0x0a,
    }, entry.msg_data.?[0..13]);
    try testing.expectEqualSlices(u8, &want_authcode, entry.msg_data.?[13..29]);
    try testing.expectEqualSlices(u8, &.{
        0x0a,
        0x20,
        0xba,
        0x26,
        0x81,
        0x48,
        0x9b,
        0x71,
        0x72,
        0x73,
        0x46,
    }, entry.msg_data.?[29..40]);
}

test "build_cmd uses the MD2 hook for authtype MD2" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();
    t.session.active = 1;
    t.session.authtype = c.IPMI_SESSION_AUTHTYPE_MD2;
    curr_seq = 0x11;

    const entry = buildCmd(&t.intf, &t.req, 0).?;

    try testing.expectEqual(@as(u8, 0x01), entry.msg_data.?[4]);
    // MD2 left OpenSSL 3 and ipmitool never had its own, so the authcode slot
    // is overwritten with the sixteen zero bytes `ipmi_auth_md2` returns --
    // which is still distinguishable from both the MD5 answer and the raw
    // password left in place for authtype PASSWORD.
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), entry.msg_data.?[13..29]);
}

test "build_cmd leaves the authcode alone for a straight-password session" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();
    t.session.active = 1;
    t.session.authtype = c.IPMI_SESSION_AUTHTYPE_PASSWORD;
    curr_seq = 0x11;

    const entry = buildCmd(&t.intf, &t.req, 0).?;

    try testing.expectEqual(@as(u8, 0x04), entry.msg_data.?[4]);
    try testing.expectEqualSlices(u8, &t_authcode, entry.msg_data.?[13..29]);
}

test "build_cmd wraps a bridged request in one Send Message" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();
    t.intf.target_addr = 0x42;
    t.intf.target_channel = 0x03;
    bridge_possible = 1;
    curr_seq = 0x11;

    const entry = buildCmd(&t.intf, &t.req, 0).?;
    try testing.expectEqual(@as(c_int, 1), entry.bridging_level);

    // The outer request is filed as Send Message; the real command moves to
    // `target_cmd`, which is what Note 5 is about.
    try testing.expectEqual(@as(u8, 0x34), entry.req.msg.cmd);
    try testing.expectEqual(@as(u8, 0x9b), entry.req.msg.target_cmd);
    // The caller's own request is untouched.
    try testing.expectEqual(@as(u8, 0x9b), t.req.msg.cmd);

    try expectPacket(entry, &.{
        0x06, 0x00, 0xff, 0x07,
        0x00, 0x84, 0x73, 0x62,
        0x51, 0x0d, 0x0c, 0x0b,
        0x0a,
        0x12, //             message length: data_len + 15
        0x20, 0x18, 0xc8, // BMC addr, netfn App<<2, csum
        0x81, 0x48, 0x34, // rq_addr, rq_seq<<2, Send Message
        0x43, //             0x40 (track request) | target channel 3
        0x42, 0xba, 0x04, // target addr, netfn<<2|lun, inner csum1
        0x20, 0x48, 0x9b, // my_addr, rq_seq<<2, cmd
        0x71, 0x72, 0x73,
        0xa7, //             inner csum2
        0xc0, //             outer csum2, over everything from rq_addr
    });
}

test "build_cmd wraps a transit-routed request in two Send Messages" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();
    t.intf.target_addr = 0x42;
    t.intf.target_channel = 0x03;
    t.intf.transit_addr = 0x56;
    t.intf.transit_channel = 0x07;
    bridge_possible = 1;
    curr_seq = 0x11;

    const entry = buildCmd(&t.intf, &t.req, 0).?;
    try testing.expectEqual(@as(c_int, 2), entry.bridging_level);

    try expectPacket(entry, &.{
        0x06, 0x00, 0xff, 0x07,
        0x00, 0x84, 0x73, 0x62,
        0x51, 0x0d, 0x0c, 0x0b,
        0x0a,
        0x1a, //             message length: data_len + 15 + 8
        0x20,
        0x18,
        0xc8,
        0x81,
        0x48,
        0x34,
        0x47, //             0x40 | transit channel 7
        0x56, 0x18, 0x92, // transit addr, netfn App<<2, csum
        0x20, 0x48, 0x34, // my_addr, rq_seq<<2, Send Message
        0x43, //             0x40 | target channel 3
        0x42,
        0xba,
        0x04,
        0x20,
        0x48,
        0x9b,
        0x71,
        0x72,
        0x73,
        0xa7, //             innermost csum2
        0x21, //             middle csum2, from cs3
        0xbc, //             outer csum2, from cs2
    });
}

test "build_cmd honours bridge_possible and the target address" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();
    t.intf.target_addr = 0x42;
    // bridge_possible stays 0, so the request goes out unbridged even though
    // the target is not us.
    curr_seq = 0x11;
    const flat = buildCmd(&t.intf, &t.req, 0).?;
    try testing.expectEqual(@as(c_int, 0), flat.bridging_level);
    try testing.expectEqual(@as(u8, ipmi.bmc_slave_addr), flat.msg_data.?[14]);

    resetLanGlobals();
    t.init();
    // Bridging is possible but the target is us, so still unbridged.
    bridge_possible = 1;
    curr_seq = 0x11;
    const self_addressed = buildCmd(&t.intf, &t.req, 0).?;
    try testing.expectEqual(@as(c_int, 0), self_addressed.bridging_level);
}

test "build_cmd falls back to the BMC slave address when my_addr is zero" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();
    t.intf.my_addr = 0;
    t.intf.target_addr = ipmi.bmc_slave_addr;
    bridge_possible = 1;
    curr_seq = 0x11;

    // `our_address` becomes 0x20, which matches `target_addr`, so no bridging.
    const entry = buildCmd(&t.intf, &t.req, 0).?;
    try testing.expectEqual(@as(c_int, 0), entry.bridging_level);
}

test "build_cmd truncates my_addr to eight bits, like the C" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();
    // `uint8_t our_address = intf->my_addr` in the C: the high bytes are lost,
    // so 0x1120 and 0x20 both compare equal to target_addr 0x20.
    t.intf.my_addr = 0x1120;
    t.intf.target_addr = ipmi.bmc_slave_addr;
    bridge_possible = 1;
    curr_seq = 0x11;

    const entry = buildCmd(&t.intf, &t.req, 0).?;
    try testing.expectEqual(@as(c_int, 0), entry.bridging_level);
}

test "build_cmd wraps the sequence number at 64" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();

    curr_seq = 62;
    _ = buildCmd(&t.intf, &t.req, 0).?;
    try testing.expectEqual(@as(c_int, 63), curr_seq);

    // 63 + 1 == 64, which is out of range for a six-bit field.
    _ = buildCmd(&t.intf, &t.req, 0).?;
    try testing.expectEqual(@as(c_int, 0), curr_seq);
}

test "build_cmd reuses the list entry on a retry and keeps the sequence" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();
    curr_seq = 0x11;

    const first = buildCmd(&t.intf, &t.req, 0).?;
    const first_seq = first.rq_seq;

    const retry = buildCmd(&t.intf, &t.req, 1).?;
    try testing.expectEqual(first, retry);
    try testing.expectEqual(first_seq, retry.rq_seq);
    try testing.expectEqual(@as(c_int, 0x12), curr_seq);

    // One entry, not two.
    try testing.expectEqual(req_entries, req_entries_tail);
    try testing.expect(req_entries.?.next == null);
}

test "build_cmd only advances a non-zero in_seq" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();

    // Note 8: a zero inbound sequence stays zero.
    t.session.in_seq = 0;
    _ = buildCmd(&t.intf, &t.req, 0).?;
    try testing.expectEqual(@as(u32, 0), t.session.in_seq);

    // ...but a wrap skips zero.
    resetLanGlobals();
    t.session.in_seq = 0xffffffff;
    _ = buildCmd(&t.intf, &t.req, 0).?;
    try testing.expectEqual(@as(u32, 1), t.session.in_seq);
}

test "the request list adds, finds and removes entries" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();

    var a_req = t.req;
    a_req.msg.cmd = 0x31;
    var b_req = t.req;
    b_req.msg.cmd = 0x42;
    var c_req = t.req;
    c_req.msg.cmd = 0x53;

    const a = reqAddEntry(&t.intf, &a_req, 0x11).?;
    const b = reqAddEntry(&t.intf, &b_req, 0x22).?;
    const e = reqAddEntry(&t.intf, &c_req, 0x33).?;

    try testing.expectEqual(a, req_entries.?);
    try testing.expectEqual(e, req_entries_tail.?);
    try testing.expectEqual(b, a.next.?);
    try testing.expectEqual(e, b.next.?);
    try testing.expect(e.next == null);
    try testing.expectEqual(&t.intf, a.intf.?);

    // Both halves of the key matter.
    try testing.expectEqual(b, reqLookupEntry(0x22, 0x42).?);
    try testing.expect(reqLookupEntry(0x22, 0x53) == null);
    try testing.expect(reqLookupEntry(0x33, 0x42) == null);

    // Removing the middle relinks its neighbours.
    reqRemoveEntry(0x22, 0x42);
    try testing.expectEqual(a, req_entries.?);
    try testing.expectEqual(e, req_entries_tail.?);
    try testing.expectEqual(e, a.next.?);
    try testing.expect(reqLookupEntry(0x22, 0x42) == null);

    // Removing the tail moves the tail back.
    reqRemoveEntry(0x33, 0x53);
    try testing.expectEqual(a, req_entries.?);
    try testing.expectEqual(a, req_entries_tail.?);
    try testing.expect(a.next == null);

    // Removing the last entry empties the list.
    reqRemoveEntry(0x11, 0x31);
    try testing.expect(req_entries == null);
    try testing.expect(req_entries_tail == null);
}

test "removing the head of a longer list promotes the second entry" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();

    var a_req = t.req;
    a_req.msg.cmd = 0x31;
    var b_req = t.req;
    b_req.msg.cmd = 0x42;

    _ = reqAddEntry(&t.intf, &a_req, 0x11).?;
    const b = reqAddEntry(&t.intf, &b_req, 0x22).?;

    reqRemoveEntry(0x11, 0x31);
    try testing.expectEqual(b, req_entries.?);
    try testing.expectEqual(b, req_entries_tail.?);
}

test "removing an absent entry leaves the list alone" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();

    var a_req = t.req;
    a_req.msg.cmd = 0x31;
    const a = reqAddEntry(&t.intf, &a_req, 0x11).?;

    reqRemoveEntry(0x99, 0x31);
    try testing.expectEqual(a, req_entries.?);
    try testing.expectEqual(a, req_entries_tail.?);
}

test "req_lookup_entry stops on a self-referential node" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();

    var a_req = t.req;
    a_req.msg.cmd = 0x31;
    const a = reqAddEntry(&t.intf, &a_req, 0x11).?;
    a.next = a;

    // Without the `e == e->next` guard this spins forever.
    try testing.expect(reqLookupEntry(0x99, 0x99) == null);
    a.next = null;
}

test "clearing the list empties both ends" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();

    var a_req = t.req;
    a_req.msg.cmd = 0x31;
    var b_req = t.req;
    b_req.msg.cmd = 0x42;
    _ = reqAddEntry(&t.intf, &a_req, 0x11).?;
    _ = reqAddEntry(&t.intf, &b_req, 0x22).?;

    reqClearEntries();
    try testing.expect(req_entries == null);
    try testing.expect(req_entries_tail == null);
}

test "build_sol_msg lays out an RMCP SOL payload" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();

    var payload = std.mem.zeroes(ipmi.V2Payload);
    const sol = &payload.payload.sol_packet;
    sol.character_count = 4;
    @memcpy(sol.data[0..4], &[_]u8{ 0x91, 0x92, 0x93, 0x94 });
    sol.packet_sequence_number = 0x0b;
    sol.acked_packet_number = 0x07;
    sol.accepted_character_count = 0x03;
    sol.is_nack = 1;
    sol.generate_break = 1;
    sol.deassert_dcd_dsr = 1;
    sol.flush_outbound = 1;

    var len: c_int = 0;
    const msg = buildSolMsg(&t.intf, &payload, &len).?;
    defer c.free(msg);

    try testing.expectEqual(@as(c_int, 23), len);
    try testing.expectEqualSlices(u8, &.{
        0x06, 0x00, 0xff, 0x07,
        0x00, //                   SOL is always authtype NONE
        0x84,
        0x73,
        0x62,
        0x51,
        0x0d, 0x0c, 0x0b, //       session id, low three bytes
        0x1a, //                   top byte + 0x10 marks the SOL payload
        0x09, //                   character_count + 5
        0x0b, 0x07, 0x03, //       packet seq, acked packet, accepted chars
        0x55, //                   nack|break|dcd_dsr|flush_outbound
        0x00, //                   the fifth SOL header byte, always zero
        0x91,
        0x92,
        0x93,
        0x94,
    }, msg[0..23]);

    try testing.expectEqual(t_in_seq + 1, t.session.in_seq);
}

test "build_sol_msg encodes the other four operation bits" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();

    var payload = std.mem.zeroes(ipmi.V2Payload);
    const sol = &payload.payload.sol_packet;
    sol.assert_ring_wor = 1;
    sol.deassert_cts = 1;
    sol.flush_inbound = 1;

    var len: c_int = 0;
    const msg = buildSolMsg(&t.intf, &payload, &len).?;
    defer c.free(msg);

    // No character data at all: 4 + 10 + 5.
    try testing.expectEqual(@as(c_int, 19), len);
    try testing.expectEqual(@as(u8, 0x05), msg[13]);
    try testing.expectEqual(@as(u8, 0x2a), msg[17]);
}

test "build_sol_msg skips a zero inbound sequence on wrap" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();
    t.session.in_seq = 0xffffffff;

    var payload = std.mem.zeroes(ipmi.V2Payload);
    var len: c_int = 0;
    const msg = buildSolMsg(&t.intf, &payload, &len).?;
    defer c.free(msg);

    try testing.expectEqual(@as(u32, 1), t.session.in_seq);
}

test "the SOL packet sequence number wraps to one after fifteen" {
    resetLanGlobals();
    defer resetLanGlobals();

    var t: TestIntf = undefined;
    t.init();

    var payload = std.mem.zeroes(ipmi.V2Payload);

    t.session.sol_data.sequence_number = 0x0f;
    setSolPacketSequenceNumber(&t.intf, &payload);
    // 0x0f is still in range, so it is used as-is.
    try testing.expectEqual(@as(u8, 0x0f), payload.payload.sol_packet.packet_sequence_number);
    try testing.expectEqual(@as(u8, 0x10), t.session.sol_data.sequence_number);

    setSolPacketSequenceNumber(&t.intf, &payload);
    // 0x10 is out of range, so it restarts at one -- not zero, which means
    // "no sequence number" on the wire.
    try testing.expectEqual(@as(u8, 0x01), payload.payload.sol_packet.packet_sequence_number);
    try testing.expectEqual(@as(u8, 0x02), t.session.sol_data.sequence_number);
}

fn solRsp(rsp: *ipmi.Response, acked: u8, accepted: u8) void {
    rsp.* = std.mem.zeroes(ipmi.Response);
    rsp.session.payloadtype = c.IPMI_PAYLOAD_TYPE_SOL;
    rsp.payload.sol_packet.acked_packet_number = acked;
    rsp.payload.sol_packet.accepted_character_count = accepted;
}

test "a partial ACK asks for exactly the unaccepted characters" {
    var payload = std.mem.zeroes(ipmi.V2Payload);
    payload.payload_type = c.IPMI_PAYLOAD_TYPE_SOL;
    payload.payload.sol_packet.packet_sequence_number = 0x0b;
    payload.payload.sol_packet.character_count = 7;

    var rsp: ipmi.Response = undefined;

    solRsp(&rsp, 0x0b, 3);
    try testing.expectEqual(@as(c_int, 4), isSolPartialAck(&payload, &rsp));

    // A zero accepted count means "resend nothing", not "resend everything".
    solRsp(&rsp, 0x0b, 0);
    try testing.expectEqual(@as(c_int, 0), isSolPartialAck(&payload, &rsp));

    // A full ACK is not partial.
    solRsp(&rsp, 0x0b, 7);
    try testing.expectEqual(@as(c_int, 0), isSolPartialAck(&payload, &rsp));

    // Neither is an over-ACK.
    solRsp(&rsp, 0x0b, 9);
    try testing.expectEqual(@as(c_int, 0), isSolPartialAck(&payload, &rsp));

    // An ACK for a different packet is ignored.
    solRsp(&rsp, 0x0c, 3);
    try testing.expectEqual(@as(c_int, 0), isSolPartialAck(&payload, &rsp));

    // So is a non-SOL response.
    solRsp(&rsp, 0x0b, 3);
    rsp.session.payloadtype = c.IPMI_PAYLOAD_TYPE_IPMI;
    try testing.expectEqual(@as(c_int, 0), isSolPartialAck(&payload, &rsp));

    // And a null on either side.
    solRsp(&rsp, 0x0b, 3);
    try testing.expectEqual(@as(c_int, 0), isSolPartialAck(null, &rsp));
    try testing.expectEqual(@as(c_int, 0), isSolPartialAck(&payload, null));
}

test "a resend is only offered for a payload that is itself SOL" {
    var payload = std.mem.zeroes(ipmi.V2Payload);
    payload.payload_type = c.IPMI_PAYLOAD_TYPE_IPMI;
    payload.payload.sol_packet.packet_sequence_number = 0x0b;
    payload.payload.sol_packet.character_count = 7;

    var rsp: ipmi.Response = undefined;
    solRsp(&rsp, 0x0b, 3);
    try testing.expectEqual(@as(c_int, 0), isSolPartialAck(&payload, &rsp));
}

test "a repeated SOL sequence number yields only the new tail bytes" {
    resetLanGlobals();
    defer resetLanGlobals();

    var rsp = std.mem.zeroes(ipmi.Response);
    rsp.session.payloadtype = c.IPMI_PAYLOAD_TYPE_SOL;
    rsp.payload.sol_packet.packet_sequence_number = 0x05;
    rsp.data_len = 4;
    @memcpy(rsp.data[0..4], &[_]u8{ 0x61, 0x62, 0x63, 0x64 });

    // First sight of sequence 5: everything is new, and nothing moves.
    try testing.expectEqual(@as(c_int, 0), checkSolPacketForNewData(&rsp));
    try testing.expectEqual(@as(c_int, 4), rsp.data_len);
    try testing.expectEqual(@as(u8, 0x05), last_received_sequence_number);
    try testing.expectEqual(@as(u8, 4), last_received_byte_count);

    // The BMC retransmits sequence 5 with three more characters.
    rsp.data_len = 7;
    @memcpy(rsp.data[0..7], &[_]u8{ 0x61, 0x62, 0x63, 0x64, 0x75, 0x76, 0x77 });
    try testing.expectEqual(@as(c_int, 3), checkSolPacketForNewData(&rsp));
    try testing.expectEqual(@as(c_int, 3), rsp.data_len);
    try testing.expectEqualSlices(u8, &.{ 0x75, 0x76, 0x77 }, rsp.data[0..3]);

    // The remembered count is the *unaltered* length, not the trimmed one.
    try testing.expectEqual(@as(u8, 7), last_received_byte_count);
}

test "a fresh SOL sequence number passes the data through untouched" {
    resetLanGlobals();
    defer resetLanGlobals();

    last_received_sequence_number = 0x05;
    last_received_byte_count = 4;

    var rsp = std.mem.zeroes(ipmi.Response);
    rsp.session.payloadtype = c.IPMI_PAYLOAD_TYPE_SOL;
    rsp.payload.sol_packet.packet_sequence_number = 0x06;
    rsp.data_len = 3;
    @memcpy(rsp.data[0..3], &[_]u8{ 0x81, 0x82, 0x83 });

    try testing.expectEqual(@as(c_int, 0), checkSolPacketForNewData(&rsp));
    try testing.expectEqual(@as(c_int, 3), rsp.data_len);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x82, 0x83 }, rsp.data[0..3]);
    try testing.expectEqual(@as(u8, 0x06), last_received_sequence_number);
    try testing.expectEqual(@as(u8, 3), last_received_byte_count);
}

test "a zero SOL sequence number is not remembered" {
    resetLanGlobals();
    defer resetLanGlobals();

    last_received_sequence_number = 0x05;
    last_received_byte_count = 4;

    var rsp = std.mem.zeroes(ipmi.Response);
    rsp.session.payloadtype = c.IPMI_PAYLOAD_TYPE_SOL;
    rsp.payload.sol_packet.packet_sequence_number = 0;
    rsp.data_len = 3;

    _ = checkSolPacketForNewData(&rsp);
    try testing.expectEqual(@as(u8, 0x05), last_received_sequence_number);
    try testing.expectEqual(@as(u8, 4), last_received_byte_count);
}

test "a non-SOL payload is never trimmed" {
    resetLanGlobals();
    defer resetLanGlobals();

    last_received_sequence_number = 0x05;
    last_received_byte_count = 4;

    var rsp = std.mem.zeroes(ipmi.Response);
    rsp.session.payloadtype = c.IPMI_PAYLOAD_TYPE_IPMI;
    rsp.payload.sol_packet.packet_sequence_number = 0x05;
    rsp.data_len = 7;

    try testing.expectEqual(@as(c_int, 0), checkSolPacketForNewData(&rsp));
    try testing.expectEqual(@as(c_int, 7), rsp.data_len);
    try testing.expect(checkSolPacketForNewData(null) == 0);
}

test "handle_pong reads the supported-entities byte" {
    // A whole pong with distinct non-zero bytes everywhere, so reading the
    // wrong offset gives a different answer.
    var rsp = std.mem.zeroes(ipmi.Response);
    const pong = [_]u8{
        0x06, 0x00, 0xff, 0x06, //             rmcp header
        0x00, 0x00, 0x11, 0xbe, //             asf iana
        0x40, 0x31, 0x00, 0x10, //             type, tag, reserved, len
        0x00, 0x00, 0x11, 0xbe, //             iana
        0x51, 0x62, 0x73, 0x84, //             oem
        0x81, //                               sup_entities: IPMI supported, 1.0
        0x42, //                               sup_interact
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    };
    @memcpy(rsp.data[0..pong.len], &pong);
    rsp.data_len = pong.len;

    try testing.expectEqual(@as(c_int, 1), handlePong(&rsp));

    // Clearing only bit 7 of that one byte flips the answer.
    rsp.data[20] = 0x01;
    try testing.expectEqual(@as(c_int, 0), handlePong(&rsp));

    try testing.expectEqual(@as(c_int, -1), handlePong(null));
}

test "the authtype bitmask shifts in 32 bits, as the C does" {
    // 0b0001_1010
    const bits: u8 = 0x1a;
    try testing.expect(!authTypeBit(bits, 0));
    try testing.expect(authTypeBit(bits, 1));
    try testing.expect(!authTypeBit(bits, 2));
    try testing.expect(authTypeBit(bits, 3));
    try testing.expect(authTypeBit(bits, 4));
    try testing.expect(!authTypeBit(bits, 5));
    try testing.expect(!authTypeBit(bits, 7));

    // `1 << t` for t >= 32 is undefined in C; on the architectures ipmitool
    // builds for it wraps modulo 32, and the port reproduces that rather than
    // panicking on an out-of-range shift.
    try testing.expect(authTypeBit(bits, 33));
    try testing.expect(!authTypeBit(bits, 32));
}

test "setup installs the LAN payload maxima" {
    var i = std.mem.zeroes(Intf);
    try testing.expectEqual(@as(c_int, 0), setup(&i));
    try testing.expectEqual(@as(u16, 38), i.max_request_data_size);
    try testing.expectEqual(@as(u16, 34), i.max_response_data_size);
}

test "the request size clamp leaves room for a seven byte header" {
    var i = std.mem.zeroes(Intf);

    setMaxRqDataSize(&i, 0x10);
    try testing.expectEqual(@as(u16, 0x10), i.max_request_data_size);

    // 248 + 7 == 255, which still fits in the one-byte length field.
    setMaxRqDataSize(&i, 248);
    try testing.expectEqual(@as(u16, 248), i.max_request_data_size);

    // 249 + 7 == 256 does not.
    setMaxRqDataSize(&i, 249);
    try testing.expectEqual(@as(u16, 248), i.max_request_data_size);

    setMaxRqDataSize(&i, 0xffff);
    try testing.expectEqual(@as(u16, 248), i.max_request_data_size);
}

test "the response size clamp leaves room for an eight byte header" {
    var i = std.mem.zeroes(Intf);

    setMaxRpDataSize(&i, 0x10);
    try testing.expectEqual(@as(u16, 0x10), i.max_response_data_size);

    setMaxRpDataSize(&i, 247);
    try testing.expectEqual(@as(u16, 247), i.max_response_data_size);

    setMaxRpDataSize(&i, 248);
    try testing.expectEqual(@as(u16, 247), i.max_response_data_size);

    setMaxRpDataSize(&i, 0xffff);
    try testing.expectEqual(@as(u16, 247), i.max_response_data_size);
}

test "the vtable advertises the name and description ipmitool -h prints" {
    try testing.expectEqualStrings("lan", std.mem.sliceTo(&lan_intf.name, 0));
    try testing.expectEqualStrings(
        "IPMI v1.5 LAN Interface",
        std.mem.sliceTo(&lan_intf.desc, 0),
    );
    try testing.expectEqual(@as(u32, ipmi.bmc_slave_addr), lan_intf.target_addr);
    try testing.expect(lan_intf.setup != null);
    try testing.expect(lan_intf.open != null);
    try testing.expect(lan_intf.close != null);
    try testing.expect(lan_intf.sendrecv != null);
    try testing.expect(lan_intf.recv_sol != null);
    try testing.expect(lan_intf.send_sol != null);
    try testing.expect(lan_intf.keepalive != null);
    try testing.expect(lan_intf.set_max_request_data_size != null);
    try testing.expect(lan_intf.set_max_response_data_size != null);
    // `lan.c` leaves this unset, and `ipmi_intf_load()` must not invent it.
    try testing.expect(lan_intf.set_my_addr == null);
}

// ---------------------------------------------------------------------------
// Receive path
// ---------------------------------------------------------------------------
//
// `tests/transport/` drives this through a model BMC that always answers
// correctly, so it cannot reach the branches that exist for BMCs which do
// not: an authenticated reply inside an unauthenticated session, a `Send
// Message` wrapper with nothing inside it, or an SOL payload.  These do.

/// A response transcript: outer RMCP + v1.5 session header, then the message.
const rx_seq_bytes = [_]u8{ 0xa1, 0xb2, 0xc3, 0xd4 };

/// `session_id` as the BMC echoes it, native byte order.
const rx_id_bytes = [_]u8{ 0x0d, 0x0c, 0x0b, 0x0a };

fn rxIntf(t: *TestIntf, w: Wire) void {
    t.init();
    t.intf.fd = w.tool;
    t.intf.opened = 1;
    // A zero timeout makes the `select()` in `recv_packet` return at once when
    // there is nothing queued, which is how the "no more datagrams" cases end.
    t.intf.ssn_params.timeout = 0;
    t.intf.ssn_params.retry = 1;
}

test "poll_recv parses an unauthenticated v1.5 response" {
    resetLanGlobals();
    defer resetLanGlobals();

    const w = try Wire.init();
    defer w.deinit();

    var t: TestIntf = undefined;
    rxIntf(&t, w);

    var entry_req = t.req;
    entry_req.msg.cmd = 0x9b;
    _ = reqAddEntry(&t.intf, &entry_req, 0x12).?;

    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x07,
        0x00, //                                 authtype NONE
        0xa1, 0xb2, 0xc3, 0xd4, //               session sequence
        0x0d, 0x0c, 0x0b, 0x0a, //               session id
        0x0b, //                                 message length
        0x81, 0x1e, 0xc1, //                     rq_addr, netfn 7 / rq lun 2, csum
        0x20, 0x49, 0x9b, //                     rs_addr, rq_seq 0x12 / rs lun 1, cmd
        0x00, //                                 completion code
        0x31, 0x42, 0x53, //                     data
        0xc2, //                                 csum2
    });

    const rsp = pollRecv(&t.intf).?;

    try testing.expectEqual(@as(u8, 0), rsp.session.authtype);
    try testing.expectEqual(@as(u32, 0xd4c3b2a1), rsp.session.seq);
    try testing.expectEqual(t_session_id, rsp.session.id);
    try testing.expectEqual(@as(u16, 0x0b), rsp.session.msglen);
    try testing.expectEqual(
        @as(u8, c.IPMI_PAYLOAD_TYPE_IPMI),
        rsp.session.payloadtype,
    );

    const p = &rsp.payload.ipmi_response;
    try testing.expectEqual(@as(u8, 0x81), p.rq_addr);
    try testing.expectEqual(@as(u8, 0x07), p.netfn);
    try testing.expectEqual(@as(u8, 0x02), p.rq_lun);
    try testing.expectEqual(@as(u8, 0x20), p.rs_addr);
    try testing.expectEqual(@as(u8, 0x12), p.rq_seq);
    try testing.expectEqual(@as(u8, 0x01), p.rs_lun);
    try testing.expectEqual(@as(u8, 0x9b), p.cmd);
    try testing.expectEqual(@as(u8, 0x00), rsp.ccode);

    // The header and the trailing checksum are both gone.
    try testing.expectEqual(@as(c_int, 3), rsp.data_len);
    try testing.expectEqualSlices(u8, &.{ 0x31, 0x42, 0x53 }, rsp.data[0..3]);

    // The matched entry is taken off the list.
    try testing.expect(req_entries == null);
}

test "poll_recv skips the authcode of an authenticated response" {
    resetLanGlobals();
    defer resetLanGlobals();

    const w = try Wire.init();
    defer w.deinit();

    var t: TestIntf = undefined;
    rxIntf(&t, w);
    t.session.active = 1;
    t.session.authtype = c.IPMI_SESSION_AUTHTYPE_MD5;

    var entry_req = t.req;
    entry_req.msg.cmd = 0x9b;
    _ = reqAddEntry(&t.intf, &entry_req, 0x12).?;

    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x07,
        0x02, //                                 authtype MD5
        0xa1,
        0xb2,
        0xc3,
        0xd4,
        0x0d,
        0x0c,
        0x0b,
        0x0a,
        // Sixteen authcode bytes, all distinct and non-zero so a skip of the
        // wrong length lands on something recognisable.
        0x31,
        0x42,
        0x53,
        0x64,
        0x75,
        0x86,
        0x97,
        0xa8,
        0xb9,
        0xca,
        0xdb,
        0xec,
        0xfd,
        0x0e,
        0x1f,
        0x20,
        0x0b,
        0x81,
        0x1c,
        0xc3,
        0x20,
        0x48,
        0x9b,
        0x00,
        0x61,
        0x62,
        0x63,
        0xc4,
    });

    const rsp = pollRecv(&t.intf).?;
    try testing.expectEqual(@as(u8, 0x9b), rsp.payload.ipmi_response.cmd);
    try testing.expectEqual(@as(c_int, 3), rsp.data_len);
    try testing.expectEqualSlices(u8, &.{ 0x61, 0x62, 0x63 }, rsp.data[0..3]);
}

test "poll_recv skips an authcode the BMC added to an unauthenticated session" {
    resetLanGlobals();
    defer resetLanGlobals();

    const w = try Wire.init();
    defer w.deinit();

    var t: TestIntf = undefined;
    rxIntf(&t, w);
    // The session was activated with authtype NONE...
    t.session.active = 1;
    t.session.authtype = 0;

    var entry_req = t.req;
    entry_req.msg.cmd = 0x9b;
    _ = reqAddEntry(&t.intf, &entry_req, 0x12).?;

    // ...but this BMC authenticates its replies anyway.  That is why the C
    // tests `rsp->session.authtype || s->authtype` rather than `&&`.
    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x07,
        0x02, 0xa1, 0xb2, 0xc3,
        0xd4, 0x0d, 0x0c, 0x0b,
        0x0a, 0x31, 0x42, 0x53,
        0x64, 0x75, 0x86, 0x97,
        0xa8, 0xb9, 0xca, 0xdb,
        0xec, 0xfd, 0x0e, 0x1f,
        0x20, 0x0b, 0x81, 0x1c,
        0xc3, 0x20, 0x48, 0x9b,
        0x00, 0x71, 0x72, 0x73,
        0xc4,
    });

    const rsp = pollRecv(&t.intf).?;
    try testing.expectEqual(@as(u8, 0x9b), rsp.payload.ipmi_response.cmd);
    try testing.expectEqualSlices(u8, &.{ 0x71, 0x72, 0x73 }, rsp.data[0..3]);
}

test "poll_recv skips an authcode that is not there when the session has one" {
    resetLanGlobals();
    defer resetLanGlobals();

    const w = try Wire.init();
    defer w.deinit();

    var t: TestIntf = undefined;
    rxIntf(&t, w);
    t.session.active = 1;
    t.session.authtype = c.IPMI_SESSION_AUTHTYPE_MD5;

    var entry_req = t.req;
    entry_req.msg.cmd = 0x9b;
    _ = reqAddEntry(&t.intf, &entry_req, 0x12).?;

    // The other half of the `||`: a BMC that drops the authcode from a reply
    // inside an authenticated session.  The C skips sixteen bytes regardless,
    // reads past the message, finds no matching entry and gives up.  Preserved
    // rather than fixed.
    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x07,
        0x00, 0xa1, 0xb2, 0xc3,
        0xd4, 0x0d, 0x0c, 0x0b,
        0x0a, 0x0b, 0x81, 0x1c,
        0xc3, 0x20, 0x48, 0x9b,
        0x00, 0x71, 0x72, 0x73,
        0xc4,
    });

    try testing.expect(pollRecv(&t.intf) == null);
}

test "poll_recv parses an SOL payload" {
    resetLanGlobals();
    defer resetLanGlobals();

    const w = try Wire.init();
    defer w.deinit();

    var t: TestIntf = undefined;
    rxIntf(&t, w);

    // 0x0a0b0c0d + 0x10000000, native byte order.
    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x07,
        0x00, 0xa1, 0xb2, 0xc3,
        0xd4, 0x0d, 0x0c, 0x0b,
        0x1a,
        0x09, //                                 message length
        0x3b, //                                 packet sequence, low nibble
        0x37, //                                 acked packet, low nibble
        0x03, //                                 accepted character count
        0x54, //                                 nack | inactive | break
        0x00, //                                 the fifth SOL header byte
        0x61,
        0x62,
        0x63,
        0x64,
    });

    const rsp = pollRecv(&t.intf).?;
    try testing.expectEqual(
        @as(u8, c.IPMI_PAYLOAD_TYPE_SOL),
        rsp.session.payloadtype,
    );

    const p = &rsp.payload.sol_packet;
    try testing.expectEqual(@as(u8, 0x0b), p.packet_sequence_number);
    try testing.expectEqual(@as(u8, 0x07), p.acked_packet_number);
    try testing.expectEqual(@as(u8, 0x03), p.accepted_character_count);
    try testing.expectEqual(@as(u8, 0x40), p.is_nack);
    try testing.expectEqual(@as(u8, 0x00), p.transfer_unavailable);
    try testing.expectEqual(@as(u8, 0x10), p.sol_inactive);
    try testing.expectEqual(@as(u8, 0x00), p.transmit_overrun);
    try testing.expectEqual(@as(u8, 0x04), p.break_detected);

    // No checksum to strip on an SOL payload.
    try testing.expectEqual(@as(c_int, 4), rsp.data_len);
    try testing.expectEqualSlices(u8, &.{ 0x61, 0x62, 0x63, 0x64 }, rsp.data[0..4]);
}

test "poll_recv unwraps a bridged response carried inside the Send Message reply" {
    resetLanGlobals();
    defer resetLanGlobals();

    const w = try Wire.init();
    defer w.deinit();

    var t: TestIntf = undefined;
    rxIntf(&t, w);
    t.intf.target_addr = 0x42;
    bridge_possible = 1;

    var entry_req = t.req;
    entry_req.msg.cmd = 0x34;
    entry_req.msg.target_cmd = 0x9b;
    const e = reqAddEntry(&t.intf, &entry_req, 0x12).?;
    e.bridging_level = 1;

    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x07,
        0x00, 0xa1, 0xb2, 0xc3,
        0xd4, 0x0d, 0x0c, 0x0b,
        0x0a,
        0x13, //                                 outer message length: 19
        0x81, 0x1c, 0xc3, //                     outer rq_addr, netfn 7, csum
        0x20, 0x48, 0x34, //                     rs_addr, rq_seq 0x12, Send Message
        0x00, //                                 outer completion code
        // The bridged answer, eleven bytes.
        0x81,
        0x1c,
        0xc5,
        0x20,
        0x48,
        0x9b,
        0x00,
        0x31,
        0x42,
        0x53,
        0xc6,
        0xc4, //                                 outer csum2
    });

    const rsp = pollRecv(&t.intf).?;

    // The outer envelope is gone: eight bytes off the front and off both
    // length fields.
    try testing.expectEqual(@as(u16, 0x0b), rsp.session.msglen);
    try testing.expectEqual(@as(u8, 0x9b), rsp.payload.ipmi_response.cmd);
    try testing.expectEqual(@as(u8, 0x12), rsp.payload.ipmi_response.rq_seq);
    try testing.expectEqual(@as(c_int, 3), rsp.data_len);
    try testing.expectEqualSlices(u8, &.{ 0x31, 0x42, 0x53 }, rsp.data[0..3]);
    try testing.expect(req_entries == null);
}

test "poll_recv waits for a second datagram when the Send Message reply is empty" {
    resetLanGlobals();
    defer resetLanGlobals();

    const w = try Wire.init();
    defer w.deinit();

    var t: TestIntf = undefined;
    rxIntf(&t, w);
    t.intf.target_addr = 0x42;
    bridge_possible = 1;

    var entry_req = t.req;
    entry_req.msg.cmd = 0x34;
    entry_req.msg.target_cmd = 0x9b;
    const e = reqAddEntry(&t.intf, &entry_req, 0x12).?;
    e.bridging_level = 1;

    // A Send Message reply with nothing after the completion code.  The C
    // reads another datagram for the bridged answer; here none arrives, so it
    // gives up and drops the entry -- which is what tells this case apart from
    // the "answer is embedded" one above.
    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x07,
        0x00, 0xa1, 0xb2, 0xc3,
        0xd4, 0x0d, 0x0c, 0x0b,
        0x0a, 0x08, 0x81, 0x1c,
        0xc3, 0x20, 0x48, 0x34,
        0x00, 0xc4,
    });

    try testing.expect(pollRecv(&t.intf) == null);
    try testing.expect(req_entries == null);
    // Nothing was shifted or rewritten: the message length byte is untouched.
    try testing.expectEqual(@as(u8, 0x08), recv_rsp.data[13]);
}

test "poll_recv keeps reading past a datagram it cannot match" {
    resetLanGlobals();
    defer resetLanGlobals();

    const w = try Wire.init();
    defer w.deinit();

    var t: TestIntf = undefined;
    rxIntf(&t, w);

    var entry_req = t.req;
    entry_req.msg.cmd = 0x9b;
    _ = reqAddEntry(&t.intf, &entry_req, 0x12).?;

    // A late answer to an abandoned request: right shape, wrong sequence.
    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x07,
        0x00, 0xa1, 0xb2, 0xc3,
        0xd4, 0x0d, 0x0c, 0x0b,
        0x0a, 0x0b, 0x81, 0x1c,
        0xc3, 0x20, 0x44, 0x9b,
        0x00, 0x11, 0x22, 0x33,
        0xc4,
    });
    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x07,
        0x00, 0xa1, 0xb2, 0xc3,
        0xd4, 0x0d, 0x0c, 0x0b,
        0x0a, 0x0b, 0x81, 0x1c,
        0xc3, 0x20, 0x48, 0x9b,
        0x00, 0x31, 0x42, 0x53,
        0xc4,
    });

    const rsp = pollRecv(&t.intf).?;
    try testing.expectEqual(@as(u8, 0x12), rsp.payload.ipmi_response.rq_seq);
    try testing.expectEqualSlices(u8, &.{ 0x31, 0x42, 0x53 }, rsp.data[0..3]);
}

test "poll_recv skips a datagram that is not an RMCP IPMI packet" {
    resetLanGlobals();
    defer resetLanGlobals();

    const w = try Wire.init();
    defer w.deinit();

    var t: TestIntf = undefined;
    rxIntf(&t, w);

    var entry_req = t.req;
    entry_req.msg.cmd = 0x9b;
    _ = reqAddEntry(&t.intf, &entry_req, 0x12).?;

    // RMCP class 0x05 is neither ASF nor IPMI.  Every other byte is a valid
    // IPMI response that would match the outstanding entry, so the class check
    // is the only thing that can keep it out of the answer.
    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x05,
        0x00, 0xa1, 0xb2, 0xc3,
        0xd4, 0x0d, 0x0c, 0x0b,
        0x0a, 0x0b, 0x81, 0x1c,
        0xc3, 0x20, 0x48, 0x9b,
        0x00, 0x71, 0x82, 0x93,
        0xc4,
    });
    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x07,
        0x00, 0xa1, 0xb2, 0xc3,
        0xd4, 0x0d, 0x0c, 0x0b,
        0x0a, 0x0b, 0x81, 0x1c,
        0xc3, 0x20, 0x48, 0x9b,
        0x00, 0x31, 0x42, 0x53,
        0xc4,
    });

    const rsp = pollRecv(&t.intf).?;
    try testing.expectEqualSlices(u8, &.{ 0x31, 0x42, 0x53 }, rsp.data[0..3]);
}

test "poll_recv returns the pong for an ASF datagram" {
    resetLanGlobals();
    defer resetLanGlobals();

    const w = try Wire.init();
    defer w.deinit();

    var t: TestIntf = undefined;
    rxIntf(&t, w);

    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x06,
        0x00, 0x00, 0x11, 0xbe,
        0x40, 0x31, 0x00, 0x10,
        0x00, 0x00, 0x11, 0xbe,
        0x51, 0x62, 0x73, 0x84,
        0x81, 0x42, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    });
    try testing.expect(pollRecv(&t.intf) != null);

    // A pong that does not claim IPMI support is discarded.
    try w.send(&[_]u8{
        0x06, 0x00, 0xff, 0x06,
        0x00, 0x00, 0x11, 0xbe,
        0x40, 0x31, 0x00, 0x10,
        0x00, 0x00, 0x11, 0xbe,
        0x51, 0x62, 0x73, 0x84,
        0x01, 0x42, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    });
    try testing.expect(pollRecv(&t.intf) == null);
}

test "send_cmd writes the built packet and clears the request list" {
    resetLanGlobals();
    defer resetLanGlobals();

    const w = try Wire.init();
    defer w.deinit();

    var t: TestIntf = undefined;
    rxIntf(&t, w);
    // `-N 0` style: send and do not wait, which is the only way to run
    // `ipmi_lan_send_cmd` to completion without a BMC on the other end.
    t.intf.noanswer = 1;
    curr_seq = 0x11;

    try testing.expect(sendCmd(&t.intf, &t.req) == null);

    var buf: [64]u8 = undefined;
    const got = try w.recv(&buf);
    try testing.expectEqualSlices(u8, &.{
        0x06, 0x00, 0xff, 0x07,
        0x00, 0x84, 0x73, 0x62,
        0x51, 0x0d, 0x0c, 0x0b,
        0x0a, 0x0a, 0x20, 0xba,
        0x26, 0x81, 0x48, 0x9b,
        0x71, 0x72, 0x73, 0x46,
    }, got);

    // A stale entry here would let a very slow controller's answer to an
    // abandoned request match the next command.
    try testing.expect(req_entries == null);
    try testing.expect(req_entries_tail == null);
}

test "open applies the compiled-in LAN defaults before it needs a socket" {
    resetLanGlobals();
    defer resetLanGlobals();

    var i = std.mem.zeroes(Intf);
    // No hostname, so `open` bails out after filling in the defaults and
    // before `ipmi_intf_socket_connect`.
    try testing.expectEqual(@as(c_int, -1), open(&i));

    try testing.expectEqual(@as(c_int, 0x26f), i.ssn_params.port);
    try testing.expectEqual(@as(u32, 2), i.ssn_params.timeout);
    try testing.expectEqual(@as(c_int, 4), i.ssn_params.retry);
    try testing.expectEqual(
        @as(u8, c.IPMI_SESSION_PRIV_ADMIN),
        i.ssn_params.privlvl,
    );

    // Anything already set on the command line is left alone.
    var j = std.mem.zeroes(Intf);
    j.ssn_params.port = 0x1234;
    j.ssn_params.timeout = 0x11;
    j.ssn_params.retry = 0x22;
    j.ssn_params.privlvl = c.IPMI_SESSION_PRIV_OPERATOR;
    try testing.expectEqual(@as(c_int, -1), open(&j));
    try testing.expectEqual(@as(c_int, 0x1234), j.ssn_params.port);
    try testing.expectEqual(@as(u32, 0x11), j.ssn_params.timeout);
    try testing.expectEqual(@as(c_int, 0x22), j.ssn_params.retry);
    try testing.expectEqual(
        @as(u8, c.IPMI_SESSION_PRIV_OPERATOR),
        j.ssn_params.privlvl,
    );

    // An already-open interface is refused before anything is touched.
    var k = std.mem.zeroes(Intf);
    k.opened = 1;
    try testing.expectEqual(@as(c_int, -1), open(&k));
    try testing.expectEqual(@as(c_int, 0), k.ssn_params.port);
}
