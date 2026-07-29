//! A deterministic model BMC that speaks RMCP, IPMI v1.5 and RMCP+ over UDP.
//!
//! This is the oracle the transport fixtures are recorded against.  It is not a
//! replay of a captured stream: it parses every datagram the tool under test
//! sends, validates everything a real BMC would validate (checksums, declared
//! lengths, session ids, sequence numbers, RAKP authentication codes,
//! confidentiality padding) and answers with a response derived from fixed,
//! committed constants.  Every value it invents is a constant in
//! `Personality`, so the whole exchange is reproducible byte for byte.
//!
//! It writes a text transcript as it goes.  Recording and checking run the
//! *same* code: `zig build gen-transport-fixtures` writes the transcript to
//! `tests/transport/fixtures/`, and `zig build test-transport` produces it
//! again and compares.  There is no second, "replay only" implementation that
//! could drift from this one.
//!
//! ## What is masked, and why that is safe
//!
//! Three things in a real exchange cannot be reproduced across runs.  Each is
//! rendered as `??` in the transcript, at a *fixed offset* and with a *fixed
//! length*, so the mask pins the geometry even where it cannot pin the value:
//!
//! * the four random bytes of the initial outbound sequence number in the IPMI
//!   v1.5 Activate Session request (`get_random(msg_data+18, 4)` in `lan.c`);
//! * Rm, the 16 byte console random number in RAKP 1 (`lanplus_rand`);
//! * anything derived from Rm: the RMCP+ integrity AuthCode trailer, and the
//!   AES-CBC confidentiality header and body, whose key comes from the SIK.
//!
//! Masked bytes are *not* unchecked.  The AuthCode trailer is recomputed here
//! from the Rm actually received and the result is written into the transcript
//! as `authcode=ok` or `authcode=BAD`; the encrypted body is decrypted and the
//! plaintext is emitted on a `pln` line, which is compared byte for byte like
//! any other.  So the only bytes in the whole transcript that are genuinely
//! unpinned are 4 + 16 = 20 bytes of raw entropy per session.

const std = @import("std");
const crypto = @import("crypto.zig");
const Transcript = @import("Transcript.zig");

// -- constants from the C ---------------------------------------------------

/// `RMCP_VERSION_1` in include/ipmitool/ipmi.h.
const rmcp_version_1 = 0x06;
const rmcp_class_asf = 0x06;
const rmcp_class_ipmi = 0x07;
const asf_rmcp_iana = 0x000011be;
const asf_type_ping = 0x80;
const asf_type_pong = 0x40;

/// `IPMI_BMC_SLAVE_ADDR` / `IPMI_REMOTE_SWID` in include/ipmitool/ipmi.h.
const bmc_slave_addr = 0x20;
const remote_swid = 0x81;

const netfn_app = 0x06;
const netfn_storage = 0x0a;

/// `IPMI_LANPLUS_OFFSET_*` in src/plugins/lanplus/lanplus.h.
const off_authtype = 0x04;
const off_payload_type = 0x05;
const off_session_id = 0x06;
const off_sequence_num = 0x0a;
const off_payload_size = 0x0e;
const off_payload = 0x10;

const payload_type_ipmi = 0x00;
const payload_type_open_request = 0x10;
const payload_type_open_response = 0x11;
const payload_type_rakp_1 = 0x12;
const payload_type_rakp_2 = 0x13;
const payload_type_rakp_3 = 0x14;
const payload_type_rakp_4 = 0x15;

/// `ipmi_csum` in lib/helper.c: the two's complement of the byte sum.
pub fn csum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return 0 -% sum;
}

// -- configuration ----------------------------------------------------------

/// Everything the model BMC invents rather than derives.
///
/// These are constants so that a recorded transcript is reproducible; a real
/// BMC would pick most of them at random.
pub const Personality = struct {
    /// The user the BMC knows about.  Checked against the name on the wire in
    /// both Get Session Challenge (v1.5) and RAKP 1 (v2.0), so it is the BMC
    /// side detector for the 16 byte truncation in
    /// `ipmi_intf_session_set_username()`.
    username: []const u8 = "",
    /// Its password.  Zero padded to 20 bytes to make Kuid.
    password: []const u8 = "",
    /// Kg.  `null` means "two-key login disabled", so the SIK is keyed with
    /// Kuid.
    kg: ?[]const u8 = null,

    /// IPMI v1.5 "authentication type support" bitmask in the Get Channel
    /// Authentication Capabilities response.  Bit n is authtype n.
    auth_types: u8 = (1 << 0) | (1 << 2), // NONE and MD5
    /// Set the "IPMI v2.0 extended capabilities available" bit and the
    /// v2.0-supported bit, which is what makes `lanplus` proceed.
    v20: bool = true,

    /// Session ids and sequence numbers the tool has to serialise back onto
    /// the wire are chosen with **four distinct non-zero bytes**.  A value like
    /// `0x00000101` would leave `>> 16` and `>> 24` indistinguishable and a
    /// short write invisible, i.e. the field's byte order and width would not
    /// be pinned at all (the lesson-1 failure mode, see
    /// doc/zig-migration/transport-fixtures.md).
    temp_session_id: u32 = 0x11223344,
    session_id: u32 = 0x0a0b0c0d,
    /// The "initial inbound sequence number" the BMC hands out; it becomes the
    /// session sequence number in every subsequent request the tool sends.
    inbound_seq: u32 = 0x51627384,
    challenge: [16]u8 = .{
        0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7,
        0xc8, 0xc9, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf,
    },

    /// SIDc.  Four distinct non-zero bytes: the tool copies this into RAKP 1,
    /// RAKP 3 and the header of every RMCP+ packet it sends afterwards.
    bmc_id: u32 = 0x5a6b7c8d,
    /// Rc.
    bmc_rand: [16]u8 = .{
        0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7,
        0xb8, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf,
    },
    /// GUIDc.  Sixteen distinct non-zero bytes.  A textbook GUID would repeat
    /// bytes between its halves, which would let a mis-ordered or
    /// mixed-endian copy alias onto the correct one inside the RAKP 2 hash
    /// input.
    bmc_guid: [16]u8 = .{
        0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7,
        0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf,
    },
    /// The BMC's own session sequence number for the packets it sends once the
    /// session is up.  Four distinct non-zero bytes for the same reason as
    /// `inbound_seq`, even though today's C tool neither validates nor echoes
    /// it: it is part of the RMCP+ integrity-code input, and a port that
    /// starts tracking it must be pinned from the first fixture.
    outbound_seq_start: u32 = 0x0a1b2c3d,

    /// 1-based indices of received datagrams the BMC silently drops instead of
    /// answering.  This is how retry behaviour is put under test without any
    /// timing dependency beyond the tool's own `-N` timeout.
    drop: []const u32 = &.{},

    /// A command the BMC never answers.  The tool then retransmits until it
    /// gives up, so the transcript contains exactly as many attempts as the
    /// retry limit: the count is pinned from both sides rather than just
    /// bounded from below the way `drop` does it.
    deaf: ?Deaf = null,

    /// Completion code to answer a Get Channel Authentication Capabilities
    /// request with.  Non-zero exercises the session-setup failure path.
    authcap_ccode: u8 = 0,
    /// Completion code for Get Session Challenge.  0x81 and 0x82 have their own
    /// messages in `ipmi_get_session_challenge_cmd`.
    challenge_ccode: u8 = 0,
    /// Completion code for Activate Session.
    activate_ccode: u8 = 0,
    /// Completion code for Set Session Privilege Level.  Non-zero sends the
    /// tool down `ipmi_lan_activate_session`'s `close_fail` path, which closes
    /// the session it has just opened.
    privlvl_ccode: u8 = 0,
    /// Completion code for Close Session.  0x87 has its own message.
    close_ccode: u8 = 0,

    /// A command the BMC answers once with 0xCF, "Duplicate Request", before
    /// answering it properly.  `ipmi_lan_send_cmd` discards such a response and
    /// polls again; no other case reaches that branch.
    dup_once: ?Deaf = null,

    /// Accept datagrams that are not RMCP at all instead of recording a
    /// violation.  `-o intelwv2` makes `lan.c` send two "thump" packets that a
    /// real BMC ignores, and they are the only way to observe them.
    tolerate_junk: bool = false,
    /// RMCP+ Open Session Response status code (0 = no errors).
    open_session_status: u8 = 0,
    /// RAKP 2 status code.
    rakp2_status: u8 = 0,
    /// When set, corrupt the RAKP 2 authentication code so the tool rejects it.
    corrupt_rakp2: bool = false,

    /// Extra (netfn, cmd) responses beyond the ones the model implements.
    /// Anything not matched answers 0xC1, "invalid command".
    extra: []const Canned = &.{},

    /// When set, the BMC serves this image as FRU device 0 through
    /// Get FRU Inventory Area Info and Read FRU Data.
    ///
    /// This is the only stateful, request-dependent responder the model has,
    /// and it exists for one reason: `read_fru_area()` sizes every Read FRU
    /// Data chunk from `ipmi_intf_get_max_response_data_size()`, so the
    /// requested byte count lands on the wire.  That makes the payload size
    /// arithmetic in `src/plugins/ipmi_intf.c` — including the per bridging
    /// level adjustments — transcript visible, which nothing else reaches.
    fru: ?[]const u8 = null,
};

pub const Deaf = struct { netfn: u8, cmd: u8 };

pub const Canned = struct {
    netfn: u8,
    cmd: u8,
    ccode: u8 = 0,
    data: []const u8 = &.{},
};

// -- state ------------------------------------------------------------------

const V15 = struct {
    /// Set once Activate Session has been answered.
    active: bool = false,
    /// Authentication type carried in the session header of requests.
    authtype: u8 = 0,
    /// The BMC's own session sequence number for the packets it sends.
    seq: u32 = 0,
    /// Highest session sequence number seen from the tool.
    last_seq: u32 = 0,
};

const V2 = struct {
    state: enum { presession, opened, rakp1, active } = .presession,
    console_id: u32 = 0,
    auth_alg: u8 = 0,
    integrity_alg: u8 = 0,
    crypt_alg: u8 = 0,
    role: u8 = 0,
    console_rand: [16]u8 = @splat(0),
    username_buf: [16]u8 = @splat(0),
    username_len: u8 = 0,
    keys: crypto.Keys = .{},
    seq: u32 = 0,

    fn username(v: *const V2) []const u8 {
        return v.username_buf[0..v.username_len];
    }
};

gpa: std.mem.Allocator,
t: *Transcript,
p: Personality,
frame: u32 = 0,
received: u32 = 0,
/// Number of protocol violations the BMC detected.  Reported separately from
/// the transcript comparison so a run can fail loudly even if the transcript
/// happens to match.
violations: u32 = 0,
v15: V15 = .{},
v2: V2 = .{},
/// Send Message nesting depth, so a bridged request cannot recurse forever.
bridge_depth: u8 = 0,
/// Whether `Personality.dup_once` has already fired.
dup_fired: bool = false,
hex_scratch: [2]u8 = undefined,

const Bmc = @This();

pub fn init(gpa: std.mem.Allocator, t: *Transcript, p: Personality) Bmc {
    return .{ .gpa = gpa, .t = t, .p = p };
}

fn kuid(b: *const Bmc) [20]u8 {
    var key: [20]u8 = @splat(0);
    const n = @min(key.len, b.p.password.len);
    @memcpy(key[0..n], b.p.password[0..n]);
    return key;
}

fn kgKey(b: *const Bmc) ?[20]u8 {
    const kg = b.p.kg orelse return null;
    var key: [20]u8 = @splat(0);
    const n = @min(key.len, kg.len);
    @memcpy(key[0..n], kg[0..n]);
    return key;
}

fn rakpInputs(b: *const Bmc) crypto.Rakp {
    return .{
        .console_id = b.v2.console_id,
        .bmc_id = b.p.bmc_id,
        .console_rand = b.v2.console_rand,
        .bmc_rand = b.p.bmc_rand,
        .bmc_guid = b.p.bmc_guid,
        .role = b.v2.role,
        .username = b.v2.username(),
        .password_key = b.kuid(),
        .kg = b.kgKey(),
    };
}

/// Two hex digits in a reusable scratch buffer, so a masked and an unmasked
/// checksum can share one format string.
fn hex2(b: *Bmc, byte: u8) []const u8 {
    _ = std.fmt.bufPrint(&b.hex_scratch, "{x:0>2}", .{byte}) catch unreachable;
    return &b.hex_scratch;
}

fn isDeaf(b: *const Bmc, m: Message) bool {
    const d = b.p.deaf orelse return false;
    return d.netfn == m.netfn and d.cmd == m.cmd;
}

fn fail(b: *Bmc, comptime fmt: []const u8, args: anytype) !void {
    b.violations += 1;
    try b.t.print("  !!! " ++ fmt ++ "\n", args);
}

// -- entry point ------------------------------------------------------------

/// Handle one datagram.  Returns the reply to send, or null for "stay silent".
///
/// The returned slice is owned by the caller's arena.
pub fn handle(b: *Bmc, request: []const u8) !?[]const u8 {
    b.received += 1;
    var reply: std.ArrayList(u8) = .empty;

    const drop = for (b.p.drop) |i| {
        if (i == b.received) break true;
    } else false;

    if (request.len < 4) {
        b.frame += 1;
        try b.t.frame(b.frame, .in, request, &.{}, "runt datagram");
        try b.fail("datagram shorter than an RMCP header", .{});
        return null;
    }

    switch (request[3]) {
        rmcp_class_asf => try b.handleAsf(request, &reply, drop),
        rmcp_class_ipmi => switch (request[off_authtype]) {
            0x06 => try b.handleV2(request, &reply, drop),
            else => try b.handleV15(request, &reply, drop),
        },
        else => {
            b.frame += 1;
            const kind = if (b.p.tolerate_junk) "non-RMCP (ignored)" else "unknown RMCP class";
            try b.t.frame(b.frame, .in, request, &.{}, kind);
            if (!b.p.tolerate_junk) {
                try b.fail("unknown RMCP class 0x{x:0>2}", .{request[3]});
            }
            return null;
        },
    }

    if (reply.items.len == 0) return null;
    return try reply.toOwnedSlice(b.gpa);
}

// -- RMCP presence ping -----------------------------------------------------

fn handleAsf(b: *Bmc, req: []const u8, reply: *std.ArrayList(u8), drop: bool) !void {
    b.frame += 1;
    const tag: u8 = if (req.len > 9) req[9] else 0;
    try b.t.frame(b.frame, .in, req, &.{}, "asf.ping");
    try b.t.print("  asf iana={x:0>8} type={x:0>2} tag={x:0>2} len={x:0>2}\n", .{
        std.mem.readInt(u32, req[4..8], .big),
        req[8],
        tag,
        req[11],
    });
    if (std.mem.readInt(u32, req[4..8], .big) != asf_rmcp_iana) {
        try b.fail("ASF IANA is not RMCP's", .{});
    }
    if (req[8] != asf_type_ping) try b.fail("ASF message type is not ping", .{});
    if (req.len != 12) try b.fail("ASF ping is {d} bytes, expected 12", .{req.len});
    if (drop) {
        try b.t.print("  (dropped: no pong)\n", .{});
        return;
    }

    const g = b.gpa;
    try reply.appendSlice(g, &.{ rmcp_version_1, 0x00, 0xff, rmcp_class_asf });
    try reply.appendSlice(g, &.{ 0x00, 0x00, 0x11, 0xbe }); // ASF IANA
    try reply.appendSlice(g, &.{ asf_type_pong, tag, 0x00, 0x10 });
    try reply.appendSlice(g, &.{ 0x00, 0x00, 0x11, 0xbe }); // OEM IANA
    try reply.appendSlice(g, &.{ 0x00, 0x00, 0x00, 0x00 }); // OEM defined
    try reply.appendSlice(g, &.{ 0x81, 0x00 }); // supported entities, interactions
    try reply.appendSlice(g, &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });

    b.frame += 1;
    try b.t.frame(b.frame, .out, reply.items, &.{}, "asf.pong");
}

// -- IPMI v1.5 --------------------------------------------------------------

/// A parsed IPMI message body: `rsAddr netFn/rsLun csum rqAddr rqSeq/rqLun cmd
/// [data] csum`.
const Message = struct {
    rs_addr: u8,
    netfn: u8,
    rs_lun: u2,
    csum1: u8,
    csum1_ok: bool,
    rq_addr: u8,
    rq_seq: u6,
    rq_lun: u2,
    cmd: u8,
    data: []const u8,
    csum2: u8,
    csum2_ok: bool,
};

fn parseMessage(bytes: []const u8) ?Message {
    if (bytes.len < 7) return null;
    return .{
        .rs_addr = bytes[0],
        .netfn = bytes[1] >> 2,
        .rs_lun = @truncate(bytes[1]),
        .csum1 = bytes[2],
        .csum1_ok = bytes[2] == csum(bytes[0..2]),
        .rq_addr = bytes[3],
        .rq_seq = @truncate(bytes[4] >> 2),
        .rq_lun = @truncate(bytes[4]),
        .cmd = bytes[5],
        .data = bytes[6 .. bytes.len - 1],
        .csum2 = bytes[bytes.len - 1],
        .csum2_ok = bytes[bytes.len - 1] == csum(bytes[3 .. bytes.len - 1]),
    };
}

fn describeMessage(
    b: *Bmc,
    m: Message,
    kind: []const u8,
    data_masks: []const Transcript.Span,
    /// The data checksum covers bytes the transcript masks, so its value
    /// varies run to run.  Its *correctness* is still asserted.
    mask_csum2: bool,
) !void {
    const response = std.mem.eql(u8, kind, "rsp");
    try b.t.print(
        "  {s} {s}={x:0>2} netfn={x:0>2} lun={d} csum1={x:0>2}:{s}" ++
            " {s}={x:0>2} rqseq={x:0>2} lun={d} cmd={x:0>2} csum2={s}:{s}\n",
        .{
            kind,
            if (response) "rqaddr" else "rsaddr",
            m.rs_addr,
            m.netfn,
            m.rs_lun,
            m.csum1,
            if (m.csum1_ok) "ok" else "BAD",
            if (response) "rsaddr" else "rqaddr",
            m.rq_addr,
            @as(u8, m.rq_seq),
            m.rq_lun,
            m.cmd,
            if (mask_csum2) "??" else b.hex2(m.csum2),
            if (m.csum2_ok) "ok" else "BAD",
        },
    );
    if (response) {
        try b.t.print("  ccc {x:0>2}\n", .{m.data[0]});
        try b.t.hexField("  dat", m.data[1..], data_masks);
    } else {
        try b.t.hexField("  dat", m.data, data_masks);
    }
}

fn handleV15(b: *Bmc, req: []const u8, reply: *std.ArrayList(u8), drop: bool) !void {
    b.frame += 1;
    const authtype = req[4];
    const has_authcode = authtype != 0;
    // rmcp(4) authtype(1) seq(4) session id(4) [authcode(16)] msglen(1)
    const hdr_len: usize = 14 + @as(usize, if (has_authcode) 16 else 0);

    // The four random bytes of the initial outbound sequence number live in
    // the Activate Session request's data at a fixed offset.  Work out where
    // they land in the datagram before rendering, so the mask is derived from
    // the packet layout and not from a hand-transcribed constant.
    var mask: [3]Transcript.Span = undefined;
    var masks: []const Transcript.Span = &.{};
    var data_mask: [1]Transcript.Span = undefined;
    var data_masks: []const Transcript.Span = &.{};
    var mask_csum2 = false;

    if (req.len < hdr_len + 7) {
        try b.t.frame(b.frame, .in, req, &.{}, "ipmi.v15 (truncated)");
        try b.fail("IPMI v1.5 datagram too short: {d} bytes", .{req.len});
        return;
    }
    const seq = std.mem.readInt(u32, req[5..9], .little);
    const session_id = std.mem.readInt(u32, req[9..13], .little);
    const msglen = req[hdr_len - 1];
    const body = req[hdr_len..];
    const m = parseMessage(body) orelse {
        try b.t.frame(b.frame, .in, req, &.{}, "ipmi.v15 (bad body)");
        try b.fail("IPMI message body too short", .{});
        return;
    };

    // `ipmi_activate_session_cmd` is the only place the v1.5 client draws
    // random bytes: four of them, at a fixed offset in the request data.  They
    // are masked, and so is everything downstream of them -- the data checksum
    // and, when the session is authenticated, the 16 byte authcode.  Position
    // and length stay pinned; only the values are free.
    if (m.netfn == netfn_app and m.cmd == 0x3a and m.data.len >= 22) {
        var n: usize = 0;
        if (has_authcode) {
            mask[n] = .{ .start = 13, .len = 16 };
            n += 1;
        }
        mask[n] = .{ .start = hdr_len + 6 + 18, .len = 4 };
        n += 1;
        mask[n] = .{ .start = req.len - 1, .len = 1 };
        n += 1;
        masks = mask[0..n];
        data_mask[0] = .{ .start = 18, .len = 4 };
        data_masks = &data_mask;
        mask_csum2 = true;
    }

    try b.t.frame(b.frame, .in, req, masks, "ipmi.v15 rq");
    try b.t.print(
        "  ssn authtype={x:0>2} seq={x:0>8} id={x:0>8} msglen={x:0>2}{s}\n",
        .{ authtype, seq, session_id, msglen, if (has_authcode) " authcode=16" else "" },
    );
    try b.describeMessage(m, "req", data_masks, mask_csum2);

    if (msglen != body.len) {
        try b.fail("declared message length {d} but {d} bytes follow", .{ msglen, body.len });
    }
    if (!m.csum1_ok) try b.fail("header checksum wrong: expected {x:0>2}", .{csum(body[0..2])});
    if (!m.csum2_ok) {
        try b.fail("data checksum wrong: expected {x:0>2}", .{csum(body[3 .. body.len - 1])});
    }
    // `ipmi_lan_build_cmd` seeds `s->in_seq` from the Activate Session response
    // and increments it for every packet it builds, retransmissions included.
    // Requiring strict growth catches a stuck or reset counter; the exact
    // values, including the per-retry increments, are pinned by the transcript.
    if (b.v15.active) {
        if (seq <= b.v15.last_seq) {
            try b.fail("session sequence {x:0>8} did not advance past {x:0>8}", .{ seq, b.v15.last_seq });
        }
        b.v15.last_seq = seq;
    }
    if (b.v15.active and session_id != b.p.session_id) {
        try b.fail("session id {x:0>8}, expected {x:0>8}", .{ session_id, b.p.session_id });
    }

    if (drop or b.isDeaf(m)) {
        try b.t.print("  (dropped: no response)\n", .{});
        return;
    }

    var buf: [512]u8 = undefined;
    var r = try b.dispatch(m, &buf);

    // The v1.5 message length is a single byte, so a response body of more than
    // 247 data bytes cannot be framed at all.  A real BMC would never produce
    // one, and the tool asking for one means it picked the wrong transport, so
    // record a violation instead of trapping on the length cast.
    if (r.data.len > 247) {
        try b.fail("v1.5 response body of {d} bytes does not fit the length byte", .{r.data.len});
        r.data = r.data[0..247];
    }

    // The response mirrors the request's session framing, which is what a real
    // BMC does and what `ipmi_lan_poll_recv` assumes when it decides whether to
    // skip 16 bytes of authcode.
    const g = b.gpa;
    try reply.appendSlice(g, &.{ rmcp_version_1, 0x00, 0xff, rmcp_class_ipmi });
    try reply.append(g, authtype);
    var seq_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &seq_bytes, b.v15.seq, .little);
    try reply.appendSlice(g, &seq_bytes);
    var id_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &id_bytes, session_id, .little);
    try reply.appendSlice(g, &id_bytes);
    if (has_authcode) try reply.appendSlice(g, &(@as([16]u8, @splat(0))));

    try reply.append(g, @intCast(8 + r.data.len));
    const body_start = reply.items.len;
    try reply.append(g, remote_swid);
    try reply.append(g, (m.netfn | 1) << 2 | @as(u8, m.rq_lun));
    try reply.append(g, csum(reply.items[body_start..]));
    const csum2_start = reply.items.len;
    try reply.append(g, bmc_slave_addr);
    try reply.append(g, @as(u8, m.rq_seq) << 2 | @as(u8, m.rs_lun));
    try reply.append(g, m.cmd);
    try reply.append(g, r.ccode);
    try reply.appendSlice(g, r.data);
    try reply.append(g, csum(reply.items[csum2_start..]));

    if (b.v15.active) {
        b.v15.seq +%= 1;
        if (b.v15.seq == 0) b.v15.seq +%= 1;
    }
    if (m.netfn == netfn_app and m.cmd == 0x3a and r.ccode == 0) {
        b.v15.active = true;
        b.v15.authtype = authtype;
        b.v15.seq = b.p.outbound_seq_start;
    }
    if (m.netfn == netfn_app and m.cmd == 0x3c and r.ccode == 0) b.v15.active = false;

    b.frame += 1;
    try b.t.frame(b.frame, .out, reply.items, &.{}, "ipmi.v15 rs");
    const rbody = reply.items[body_start..];
    if (parseMessage(rbody)) |rm| try b.describeMessage(rm, "rsp", &.{}, false);
}

const Response = struct {
    ccode: u8 = 0,
    data: []const u8 = &.{},
};

fn dispatch(b: *Bmc, m: Message, buf: []u8) !Response {
    if (b.p.dup_once) |d| {
        if (!b.dup_fired and d.netfn == m.netfn and d.cmd == m.cmd) {
            b.dup_fired = true;
            return .{ .ccode = 0xcf };
        }
    }
    for (b.p.extra) |c| {
        if (c.netfn == m.netfn and c.cmd == m.cmd) return .{ .ccode = c.ccode, .data = c.data };
    }
    if (m.netfn != netfn_app) {
        if (b.p.fru) |image| if (m.netfn == netfn_storage) switch (m.cmd) {
            // Get FRU Inventory Area Info.
            0x10 => {
                std.mem.writeInt(u16, buf[0..2], @intCast(image.len), .little);
                buf[2] = 0x00; // byte access
                return .{ .data = buf[0..3] };
            },
            // Read FRU Data.  The count the tool asks for is the thing under
            // test, so answer exactly that many bytes (clamped at the end of
            // the image) rather than whatever is convenient.
            0x11 => {
                if (m.data.len < 4) return .{ .ccode = 0xc7 };
                const off = std.mem.readInt(u16, m.data[1..3], .little);
                if (off >= image.len) return .{ .ccode = 0xc9 };
                const n = @min(@as(usize, m.data[3]), image.len - off);
                buf[0] = @intCast(n);
                @memcpy(buf[1..][0..n], image[off..][0..n]);
                return .{ .data = buf[0 .. n + 1] };
            },
            else => {},
        };
        return .{ .ccode = 0xc1 };
    }

    switch (m.cmd) {
        // Get Device ID.
        0x01 => {
            const devid = [_]u8{
                0x20, 0x81, 0x02, 0x09, 0x02, 0xbf, 0x57, 0x01,
                0x00, 0x0b, 0x09, 0x00, 0x00, 0x00, 0x00,
            };
            @memcpy(buf[0..devid.len], &devid);
            return .{ .data = buf[0..devid.len] };
        },
        // Get Channel Authentication Capabilities.
        0x38 => {
            if (b.p.authcap_ccode != 0) return .{ .ccode = b.p.authcap_ccode };
            const want_v20 = m.data.len >= 1 and (m.data[0] & 0x80) != 0 and b.p.v20;
            buf[0] = 0x01; // channel number
            buf[1] = b.p.auth_types | (if (want_v20) @as(u8, 0x80) else 0x00);
            buf[2] = 0x04; // per-message auth enabled, non-null users
            buf[3] = if (want_v20) 0x03 else 0x01;
            buf[4] = 0x00;
            buf[5] = 0x00;
            buf[6] = 0x00;
            buf[7] = 0x00;
            return .{ .data = buf[0..8] };
        },
        // Get Session Challenge.
        0x39 => {
            // `ipmi_lan_get_session_challenge` copies exactly 16 bytes out of
            // the session parameters, so this is where a username truncation
            // bug becomes visible BMC side rather than only as a byte diff.
            if (m.data.len >= 17) {
                const wire = std.mem.sliceTo(m.data[1..17], 0);
                if (!std.mem.eql(u8, wire, b.p.username)) {
                    try b.fail(
                        "Get Session Challenge username \"{s}\" is not the configured \"{s}\"",
                        .{ wire, b.p.username },
                    );
                }
            }
            if (b.p.challenge_ccode != 0) return .{ .ccode = b.p.challenge_ccode };
            std.mem.writeInt(u32, buf[0..4], b.p.temp_session_id, .little);
            @memcpy(buf[4..20], &b.p.challenge);
            return .{ .data = buf[0..20] };
        },
        // Activate Session.
        0x3a => {
            if (b.p.activate_ccode != 0) return .{ .ccode = b.p.activate_ccode };
            if (m.data.len < 22) return .{ .ccode = 0xc7 };
            // Authtype OEM is the Supermicro hack in `ipmi_lan_activate_session`:
            // the challenge field is zeroed and the authcode carries
            // `ipmi_auth_special` instead.  Every other authtype has to echo the
            // challenge the BMC handed out.
            if (m.data[0] != 0x05 and !std.mem.eql(u8, m.data[2..18], &b.p.challenge)) {
                try b.fail("Activate Session echoed the wrong challenge", .{});
            }
            if (m.data[0] == 0x05 and !std.mem.allEqual(u8, m.data[2..18], 0)) {
                try b.fail("Activate Session with authtype OEM did not zero the challenge", .{});
            }
            buf[0] = m.data[0]; // authtype
            std.mem.writeInt(u32, buf[1..5], b.p.session_id, .little);
            std.mem.writeInt(u32, buf[5..9], b.p.inbound_seq, .little);
            buf[9] = 0x04; // maximum privilege level: administrator
            return .{ .data = buf[0..10] };
        },
        // Set Session Privilege Level.
        0x3b => {
            if (b.p.privlvl_ccode != 0) return .{ .ccode = b.p.privlvl_ccode };
            buf[0] = if (m.data.len >= 1) m.data[0] else 0x04;
            return .{ .data = buf[0..1] };
        },
        // Close Session.
        0x3c => {
            if (b.p.close_ccode != 0) return .{ .ccode = b.p.close_ccode };
            return .{};
        },
        // Send Message: the bridged path.  Unwrap the encapsulated message,
        // answer it, and wrap the answer the same way, which is what makes
        // `ipmi_lan_poll_recv` take its "bridged answer data are inside the
        // incoming packet" branch.
        0x34 => {
            if (b.bridge_depth >= 2) return .{ .ccode = 0xc1 };
            if (m.data.len < 8) return .{ .ccode = 0xc7 };
            const inner_bytes = m.data[1..];
            const inner = parseMessage(inner_bytes) orelse return .{ .ccode = 0xc7 };
            try b.t.print("  brg channel={x:0>2} depth={d}\n", .{ m.data[0], b.bridge_depth + 1 });
            try b.describeMessage(inner, "enc", &.{}, false);
            if (!inner.csum1_ok) {
                try b.fail("bridged header checksum wrong: expected {x:0>2}", .{csum(inner_bytes[0..2])});
            }
            if (!inner.csum2_ok) {
                try b.fail("bridged data checksum wrong: expected {x:0>2}", .{
                    csum(inner_bytes[3 .. inner_bytes.len - 1]),
                });
            }

            b.bridge_depth += 1;
            var inner_buf: [512]u8 = undefined;
            const r = try b.dispatch(inner, &inner_buf);
            b.bridge_depth -= 1;

            var n: usize = 0;
            buf[n] = inner.rq_addr;
            n += 1;
            buf[n] = (inner.netfn | 1) << 2 | @as(u8, inner.rq_lun);
            n += 1;
            buf[n] = csum(buf[0..2]);
            n += 1;
            const cs = n;
            buf[n] = inner.rs_addr;
            n += 1;
            buf[n] = @as(u8, inner.rq_seq) << 2 | @as(u8, inner.rs_lun);
            n += 1;
            buf[n] = inner.cmd;
            n += 1;
            buf[n] = r.ccode;
            n += 1;
            @memcpy(buf[n..][0..r.data.len], r.data);
            n += r.data.len;
            buf[n] = csum(buf[cs..n]);
            n += 1;
            return .{ .data = buf[0..n] };
        },
        else => return .{ .ccode = 0xc1 },
    }
}

// -- RMCP+ ------------------------------------------------------------------

fn handleV2(b: *Bmc, req: []const u8, reply: *std.ArrayList(u8), drop: bool) !void {
    b.frame += 1;
    if (req.len < off_payload) {
        try b.t.frame(b.frame, .in, req, &.{}, "ipmi.v2 (truncated)");
        try b.fail("RMCP+ datagram too short: {d} bytes", .{req.len});
        return;
    }
    const ptype_byte = req[off_payload_type];
    const ptype = ptype_byte & 0x3f;
    const encrypted = (ptype_byte & 0x80) != 0;
    const authenticated = (ptype_byte & 0x40) != 0;
    const session_id = std.mem.readInt(u32, req[off_session_id..][0..4], .little);
    const seq = std.mem.readInt(u32, req[off_sequence_num..][0..4], .little);
    const payload_len = std.mem.readInt(u16, req[off_payload_size..][0..2], .little);

    if (off_payload + payload_len > req.len) {
        try b.t.frame(b.frame, .in, req, &.{}, "ipmi.v2 (bad payload length)");
        try b.fail("declared payload length {d} exceeds the datagram", .{payload_len});
        return;
    }
    const payload = req[off_payload..][0..payload_len];

    var spans: std.ArrayList(Transcript.Span) = .empty;
    defer spans.deinit(b.gpa);

    // Integrity trailer, if any.
    var authcode_note: []const u8 = "";
    if (authenticated) {
        const alg = crypto.Algorithm.fromIntegrityId(b.v2.integrity_alg) orelse {
            try b.t.frame(b.frame, .in, req, &.{}, "ipmi.v2 (unknown integrity alg)");
            try b.fail("integrity algorithm 0x{x:0>2} is not one we negotiated", .{b.v2.integrity_alg});
            return;
        };
        const auth_len = alg.authcodeLength();
        if (req.len < off_payload + payload_len + 2 + auth_len) {
            try b.t.frame(b.frame, .in, req, &.{}, "ipmi.v2 (short trailer)");
            try b.fail("session trailer does not fit in the datagram", .{});
            return;
        }
        const authcode = req[req.len - auth_len ..];
        var digest: [64]u8 = undefined;
        const want = crypto.hmac(
            alg,
            b.v2.keys.k1[0..b.v2.keys.k1_len],
            req[off_authtype .. req.len - auth_len],
            &digest,
        );
        authcode_note = if (std.mem.eql(u8, authcode, want[0..auth_len])) "ok" else "BAD";
        if (authcode_note[0] == 'B') try b.fail("integrity authcode does not verify", .{});
        try spans.append(b.gpa, .{ .start = req.len - auth_len, .len = auth_len });
    }

    // Confidentiality: the whole AES field varies because of the random IV, so
    // mask it and compare the decrypted plaintext instead.
    var plain_buf: [1024]u8 = undefined;
    var plain: []const u8 = payload;
    var pad_note: []const u8 = "";
    if (encrypted) {
        if (payload_len < 32 or (payload_len - 16) % crypto.aes_block != 0) {
            try b.t.frame(b.frame, .in, req, spans.items, "ipmi.v2 (bad ciphertext length)");
            try b.fail("encrypted payload length {d} is not IV + whole blocks", .{payload_len});
            return;
        }
        const iv = payload[0..16];
        var decoded: [1024]u8 = undefined;
        crypto.aesCbcDecrypt(
            b.v2.keys.k2[0..16],
            iv,
            payload[16..],
            decoded[0 .. payload_len - 16],
        );
        const body = decoded[0 .. payload_len - 16];
        const pad_len = body[body.len - 1];
        if (pad_len + 1 > body.len) {
            try b.t.frame(b.frame, .in, req, spans.items, "ipmi.v2 (bad padding)");
            try b.fail("confidentiality pad length {d} exceeds the block", .{pad_len});
            return;
        }
        const n = body.len - 1 - pad_len;
        pad_note = "ok";
        for (body[n .. body.len - 1], 1..) |pb, i| {
            if (pb != i) pad_note = "BAD";
        }
        if (crypto.confidentialityPadLength(n) != pad_len) pad_note = "BAD";
        if (pad_note[0] == 'B') try b.fail("confidentiality padding is not 1,2,3,...,n", .{});
        @memcpy(plain_buf[0..n], body[0..n]);
        plain = plain_buf[0..n];
        try spans.append(b.gpa, .{ .start = off_payload, .len = payload_len });
    }

    // RAKP 1 carries Rm, the only genuinely random field in an RMCP+ session.
    if (ptype == payload_type_rakp_1) {
        try spans.append(b.gpa, .{ .start = off_payload + 8, .len = 16 });
    }

    std.mem.sort(Transcript.Span, spans.items, {}, Transcript.Span.lessThan);
    try b.t.frame(b.frame, .in, req, spans.items, payloadName(ptype));
    try b.t.print(
        "  ssn authtype=06 payload={x:0>2} enc={d} auth={d} id={x:0>8} seq={x:0>8} len={x:0>4}\n",
        .{ ptype, @intFromBool(encrypted), @intFromBool(authenticated), session_id, seq, payload_len },
    );
    if (authenticated) try b.t.print("  ich authcode={s}\n", .{authcode_note});
    if (encrypted) {
        try b.t.print("  cnf pad={s} plain_len={d}\n", .{ pad_note, plain.len });
        try b.t.hexField("  pln", plain, &.{});
    }

    if (b.v2.state == .active and session_id != b.p.bmc_id) {
        try b.fail("session id {x:0>8}, expected {x:0>8}", .{ session_id, b.p.bmc_id });
    }

    if (drop) {
        try b.t.print("  (dropped: no response)\n", .{});
        return;
    }

    switch (ptype) {
        payload_type_open_request => try b.openSessionResponse(plain, reply),
        payload_type_rakp_1 => try b.rakp2(plain, reply),
        payload_type_rakp_3 => try b.rakp4(plain, reply),
        payload_type_ipmi => try b.v2IpmiResponse(plain, reply),
        else => {
            try b.fail("unsupported payload type 0x{x:0>2}", .{ptype});
            return;
        },
    }
}

fn payloadName(ptype: u8) []const u8 {
    return switch (ptype) {
        payload_type_ipmi => "ipmi.v2 rq",
        payload_type_open_request => "ipmi.v2 open-session-rq",
        payload_type_rakp_1 => "ipmi.v2 rakp1",
        payload_type_rakp_3 => "ipmi.v2 rakp3",
        else => "ipmi.v2 ?",
    };
}

fn openSessionResponse(b: *Bmc, payload: []const u8, reply: *std.ArrayList(u8)) !void {
    if (payload.len < 32) return b.fail("open session request is {d} bytes", .{payload.len});
    b.v2.console_id = std.mem.readInt(u32, payload[4..8], .little);
    b.v2.auth_alg = payload[12];
    b.v2.integrity_alg = payload[20];
    b.v2.crypt_alg = payload[28];
    try b.t.print(
        "  osr tag={x:0>2} privlvl={x:0>2} sidm={x:0>8} auth={x:0>2} integ={x:0>2} conf={x:0>2}\n",
        .{ payload[0], payload[1], b.v2.console_id, b.v2.auth_alg, b.v2.integrity_alg, b.v2.crypt_alg },
    );

    var body: [36]u8 = @splat(0);
    body[0] = payload[0]; // message tag
    body[1] = b.p.open_session_status;
    body[2] = 0x04; // maximum privilege level: administrator
    body[3] = 0x00;
    std.mem.writeInt(u32, body[4..8], b.v2.console_id, .little);
    std.mem.writeInt(u32, body[8..12], b.p.bmc_id, .little);
    body[12] = 0x00;
    body[15] = 0x08;
    body[16] = b.v2.auth_alg;
    body[20] = 0x01;
    body[23] = 0x08;
    body[24] = b.v2.integrity_alg;
    body[28] = 0x02;
    body[31] = 0x08;
    body[32] = b.v2.crypt_alg;

    b.v2.state = .opened;
    try b.sendV2(reply, payload_type_open_response, &body, "ipmi.v2 open-session-rs");
}

fn rakp2(b: *Bmc, payload: []const u8, reply: *std.ArrayList(u8)) !void {
    if (payload.len < 28) return b.fail("RAKP 1 message is {d} bytes", .{payload.len});
    @memcpy(&b.v2.console_rand, payload[8..24]);
    b.v2.role = payload[24];
    b.v2.username_len = @min(payload[27], 16);
    const avail = @min(@as(usize, b.v2.username_len), payload.len - 28);
    @memcpy(b.v2.username_buf[0..avail], payload[28..][0..avail]);
    b.v2.username_len = @intCast(avail);

    // The username on the wire has to be the one the BMC knows.  Without this
    // the `Personality.username` field is dead: RAKP 2 keys on the password
    // only, so a truncation bug in `ipmi_intf_session_set_username()` would
    // show up as a transcript diff but never as a BMC side violation.
    if (!std.mem.eql(u8, b.v2.username(), b.p.username)) {
        try b.fail("RAKP 1 username \"{s}\" is not the configured \"{s}\"", .{
            b.v2.username(), b.p.username,
        });
    }

    try b.t.print(
        "  rk1 tag={x:0>2} sidc={x:0>8} role={x:0>2} ulen={d} uname=\"{s}\"\n",
        .{
            payload[0],
            std.mem.readInt(u32, payload[4..8], .little),
            b.v2.role,
            b.v2.username_len,
            b.v2.username(),
        },
    );

    const inputs = b.rakpInputs();
    const alg = crypto.Algorithm.fromAuthId(b.v2.auth_alg);
    b.v2.keys = if (alg) |a| crypto.Keys.derive(a, inputs) else .{};

    var body: [128]u8 = @splat(0);
    body[0] = payload[0];
    body[1] = b.p.rakp2_status;
    std.mem.writeInt(u32, body[4..8], b.v2.console_id, .little);
    @memcpy(body[8..24], &b.p.bmc_rand);
    @memcpy(body[24..40], &b.p.bmc_guid);
    var len: usize = 40;
    if (alg) |a| {
        var scratch: [256]u8 = undefined;
        var digest: [64]u8 = undefined;
        const mac = crypto.hmac(a, &inputs.password_key, inputs.rakp2Input(&scratch), &digest);
        @memcpy(body[40..][0..mac.len], mac);
        if (b.p.corrupt_rakp2) body[40] +%= 1;
        len += mac.len;
    }

    b.v2.state = .rakp1;
    // The RAKP 2 authentication code is a function of Rm, so it varies run to
    // run exactly as Rm does.
    const spans = [_]Transcript.Span{.{ .start = off_payload + 40, .len = len - 40 }};
    try b.sendV2Masked(
        reply,
        payload_type_rakp_2,
        body[0..len],
        "ipmi.v2 rakp2",
        if (len > 40) &spans else &.{},
    );
}

fn rakp4(b: *Bmc, payload: []const u8, reply: *std.ArrayList(u8)) !void {
    if (payload.len < 8) return b.fail("RAKP 3 message is {d} bytes", .{payload.len});
    const inputs = b.rakpInputs();
    var status: []const u8 = "no-auth";
    if (crypto.Algorithm.fromAuthId(b.v2.auth_alg)) |a| {
        var scratch: [256]u8 = undefined;
        var digest: [64]u8 = undefined;
        const want = crypto.hmac(a, &inputs.password_key, inputs.rakp3Input(&scratch), &digest);
        const got = payload[8..];
        status = if (std.mem.eql(u8, got, want)) "ok" else "BAD";
        if (status[0] == 'B') try b.fail("RAKP 3 authentication code does not verify", .{});
    }
    try b.t.print("  rk3 tag={x:0>2} status={x:0>2} sidc={x:0>8} authcode={s}\n", .{
        payload[0],
        payload[1],
        std.mem.readInt(u32, payload[4..8], .little),
        status,
    });

    var body: [64]u8 = @splat(0);
    body[0] = payload[0];
    body[1] = 0x00;
    std.mem.writeInt(u32, body[4..8], b.v2.console_id, .little);
    var len: usize = 8;
    if (crypto.Algorithm.fromAuthId(b.v2.auth_alg)) |a| {
        var scratch: [256]u8 = undefined;
        var digest: [64]u8 = undefined;
        const mac = crypto.hmac(a, b.v2.keys.sik[0..b.v2.keys.sik_len], inputs.rakp4Input(&scratch), &digest);
        const n = a.authcodeLength();
        @memcpy(body[8..][0..n], mac[0..n]);
        len += n;
    }

    // RAKP 4's integrity check value is keyed with the SIK, which depends on
    // Rm.  The message itself is still part of session *setup*, so it goes out
    // unencrypted and unauthenticated: the session only becomes active once it
    // has been sent.
    const spans = [_]Transcript.Span{.{ .start = off_payload + 8, .len = len - 8 }};
    try b.sendV2Masked(
        reply,
        payload_type_rakp_4,
        body[0..len],
        "ipmi.v2 rakp4",
        if (len > 8) &spans else &.{},
    );
    b.v2.state = .active;
    b.v2.seq = b.p.outbound_seq_start;
}

fn v2IpmiResponse(b: *Bmc, payload: []const u8, reply: *std.ArrayList(u8)) !void {
    const m = parseMessage(payload) orelse return b.fail("v2 IPMI payload too short", .{});
    try b.describeMessage(m, "req", &.{}, false);
    if (!m.csum1_ok) try b.fail("header checksum wrong: expected {x:0>2}", .{csum(payload[0..2])});
    if (!m.csum2_ok) {
        try b.fail("data checksum wrong: expected {x:0>2}", .{csum(payload[3 .. payload.len - 1])});
    }
    if (b.isDeaf(m)) {
        try b.t.print("  (dropped: no response)\n", .{});
        return;
    }

    var buf: [512]u8 = undefined;
    const r = try b.dispatch(m, &buf);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(b.gpa);
    const g = b.gpa;
    try body.append(g, remote_swid);
    try body.append(g, (m.netfn | 1) << 2 | @as(u8, m.rq_lun));
    try body.append(g, csum(body.items[0..2]));
    try body.append(g, bmc_slave_addr);
    try body.append(g, @as(u8, m.rq_seq) << 2 | @as(u8, m.rs_lun));
    try body.append(g, m.cmd);
    try body.append(g, r.ccode);
    try body.appendSlice(g, r.data);
    try body.append(g, csum(body.items[3..]));

    try b.sendV2(reply, payload_type_ipmi, body.items, "ipmi.v2 rs");
}

fn sendV2(b: *Bmc, reply: *std.ArrayList(u8), ptype: u8, payload: []const u8, name: []const u8) !void {
    try b.sendV2Masked(reply, ptype, payload, name, &.{});
}

/// Frame `payload` as an RMCP+ packet, encrypting and authenticating it when the
/// session says so, and record it.
///
/// `extra_spans` are offsets *within the plaintext frame* that the caller knows
/// vary; when the payload ends up encrypted they are irrelevant because the
/// whole confidentiality field is masked anyway.
fn sendV2Masked(
    b: *Bmc,
    reply: *std.ArrayList(u8),
    ptype: u8,
    payload: []const u8,
    name: []const u8,
    extra_spans: []const Transcript.Span,
) !void {
    const g = b.gpa;
    const active = b.v2.state == .active;
    const encrypt = active and b.v2.crypt_alg != 0;
    const authenticate = active and b.v2.integrity_alg != 0;

    var spans: std.ArrayList(Transcript.Span) = .empty;
    defer spans.deinit(g);
    if (!encrypt) try spans.appendSlice(g, extra_spans);

    try reply.appendSlice(g, &.{ rmcp_version_1, 0x00, 0xff, rmcp_class_ipmi });
    try reply.append(g, 0x06);
    try reply.append(g, ptype |
        (if (encrypt) @as(u8, 0x80) else 0) |
        (if (authenticate) @as(u8, 0x40) else 0));
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, if (active) b.v2.console_id else 0, .little);
    try reply.appendSlice(g, &word);
    std.mem.writeInt(u32, &word, if (active) b.v2.seq else 0, .little);
    try reply.appendSlice(g, &word);

    var out: [1024]u8 = undefined;
    var wire: []const u8 = payload;
    if (encrypt) {
        // A real BMC draws a fresh IV per packet.  This one derives it from the
        // sequence number so the recorded ciphertext is reproducible; the tool
        // under test cannot tell the difference, because the IV is transmitted.
        var iv: [16]u8 = @splat(0);
        std.mem.writeInt(u32, iv[0..4], b.v2.seq, .little);
        iv[15] = 0xa5;
        const pad = crypto.confidentialityPadLength(payload.len);
        var block: [1024]u8 = undefined;
        @memcpy(block[0..payload.len], payload);
        for (0..pad) |i| block[payload.len + i] = @intCast(i + 1);
        block[payload.len + pad] = @intCast(pad);
        const n = payload.len + pad + 1;
        @memcpy(out[0..16], &iv);
        crypto.aesCbcEncrypt(b.v2.keys.k2[0..16], &iv, block[0..n], out[16..][0..n]);
        wire = out[0 .. 16 + n];
    }

    var len_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_bytes, @intCast(wire.len), .little);
    try reply.appendSlice(g, &len_bytes);
    try reply.appendSlice(g, wire);

    if (authenticate) {
        const alg = crypto.Algorithm.fromIntegrityId(b.v2.integrity_alg).?;
        const before = 12 + wire.len + 2;
        const pad: usize = if (before % 4 == 0) 0 else 4 - (before % 4);
        for (0..pad) |_| try reply.append(g, 0xff);
        try reply.append(g, @intCast(pad));
        try reply.append(g, 0x07);
        var digest: [64]u8 = undefined;
        const mac = crypto.hmac(
            alg,
            b.v2.keys.k1[0..b.v2.keys.k1_len],
            reply.items[off_authtype..],
            &digest,
        );
        const n = alg.authcodeLength();
        try spans.append(g, .{ .start = reply.items.len, .len = n });
        try reply.appendSlice(g, mac[0..n]);
    }

    if (encrypt) {
        try spans.append(g, .{ .start = off_payload, .len = wire.len });
    }

    if (active) {
        b.v2.seq +%= 1;
        if (b.v2.seq == 0) b.v2.seq +%= 1;
    }

    b.frame += 1;
    std.mem.sort(Transcript.Span, spans.items, {}, Transcript.Span.lessThan);
    try b.t.frame(b.frame, .out, reply.items, spans.items, name);
    if (encrypt) try b.t.hexField("  pln", payload, &.{});
}
