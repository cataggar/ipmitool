//! The transport fixture case table.
//!
//! Each case is one invocation of the real `ipmitool` binary against the model
//! BMC in `Bmc.zig`.  `${port}` in an argument is replaced with the loopback
//! UDP port the model BMC bound to.
//!
//! Case naming: `<interface>/<variant>`.  The name is the fixture file name
//! with `/` turned into `-`.
//!
//! ## Choosing the raw payloads
//!
//! Several cases send `raw` commands with hand-picked data.  The bytes are not
//! arbitrary.  `ipmi_csum()` is a two's-complement sum, so appending or
//! dropping a *zero* byte at either end of a checksum range leaves the
//! checksum unchanged: a range whose boundary bytes are zero is not pinned by
//! the checksum value.  Every payload used for checksum pinning therefore has
//! non-zero bytes at both ends, and `lan/raw-long` additionally uses a payload
//! whose bytes are all distinct so that a transposition inside the range is
//! visible in the hex even though the sum would not change.
//!
//! Interior zero bytes *are* used on purpose in `lan/raw-zeros`, because a
//! length field that is computed rather than derived from a scan is only
//! pinned by a payload that contains embedded NULs.
//!
//! The same rule governs the model BMC's own constants — session ids, session
//! sequence numbers, the challenge, SIDc, Rc and GUIDc all use distinct
//! non-zero bytes, because the tool copies them back onto the wire and a
//! zero byte would make a shift-amount or short-write mutation invisible.
//! See the `Personality` doc comments in `Bmc.zig`.

const std = @import("std");
const Bmc = @import("Bmc.zig");

pub const Case = struct {
    name: []const u8,
    /// A one line description that ends up in the fixture header.
    desc: []const u8,
    /// Arguments after argv[0].
    args: []const []const u8,
    bmc: Bmc.Personality = .{},
    /// Wall clock budget.  Retry cases need room for the tool's own timeouts.
    timeout_ms: i64 = 30_000,

    pub fn fixtureName(c: Case, buf: []u8) []const u8 {
        const n = @min(buf.len, c.name.len);
        @memcpy(buf[0..n], c.name[0..n]);
        for (buf[0..n]) |*ch| {
            if (ch.* == '/') ch.* = '-';
        }
        return buf[0..n];
    }
};

const user = "opuser";
const pass = "op-password";

/// Credentials that exactly fill the two fixed size fields the session setters
/// copy into.  `lib/ipmi_main.c` caps `-U` at 16 bytes and `-P` at 16 bytes for
/// `lan` / 20 for `lanplus`, so these are the longest values the CLI accepts
/// and every byte of both fields is distinct and non-zero.
///
/// That is what makes the copy lengths pinnable: `src/plugins/lan/lan.c:1568`
/// puts all 16 username bytes onto the wire in Get Session Challenge and
/// `ipmi_auth_md5` keys on all 16 password bytes, so a copy that stops one byte
/// short leaves a zero where a known non-zero byte belongs.  With `user`/`pass`
/// (6 and 11 bytes) the tail of both fields is already zero and neither length
/// is pinned at all.
const long_user = "AbCdEfGhIjKlMnOp";
const pass_16 = "aB1!cD2@eF3#gH4$";

/// 20 bytes, the full `IPMI_AUTHCODE_BUFFER_SIZE`.  `lib/ipmi_main.c` rejects
/// anything longer for `lanplus`, so 20 is the longest password the truncation
/// in `ipmi_intf_session_set_password()` can be driven with; RAKP keys on all
/// 20 (`lanplus_crypt.c` passes `IPMI_AUTHCODE_BUFFER_SIZE`, not `strlen`), so
/// a copy that stops at 16 leaves four zero key bytes and the RAKP 2 authcode
/// no longer verifies.
const pass_20 = "aB1!cD2@eF3#gH4$iJ5%";

/// Get Device ID, answered so that `mc info` renders a full report.  The
/// payload deliberately contains an embedded zero (the aux firmware revision)
/// and a manufacturer id that is not byte symmetric.
const device_id: Bmc.Canned = .{
    .netfn = 0x06,
    .cmd = 0x01,
    .data = &.{
        0x20, 0x81, 0x02, 0x34, 0x02, 0xbf, 0x57, 0x01,
        0x00, 0x11, 0x22, 0x00, 0x00, 0x00, 0x00,
    },
};

/// Chassis Status: four bytes, one of which is zero.
const chassis_status: Bmc.Canned = .{
    .netfn = 0x00,
    .cmd = 0x01,
    .data = &.{ 0x61, 0x10, 0x40, 0x00 },
};

const canned: []const Bmc.Canned = &.{ device_id, chassis_status };

/// `0 - sum`, the FRU "zero checksum" every area ends with.
fn fruChecksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return 0 -% sum;
}

/// A minimal but well formed 64 byte FRU image: an eight byte common header
/// pointing at a board info area.
///
/// Its only job is to be big enough that `read_fru_area()` has to split the
/// read into several Read FRU Data commands, because the byte count in each of
/// those is `ipmi_intf_get_max_response_data_size(intf) - 2` and is therefore
/// the wire visible consequence of the payload size arithmetic.
const fru_image: [64]u8 = blk: {
    var img: [64]u8 = @splat(0);

    // Common header: format version 1, board area at offset 1 * 8.
    img[0] = 0x01;
    img[3] = 0x01;
    img[7] = fruChecksum(img[0..7]);

    // Board info area: version, length in 8 byte multiples, language.
    img[8] = 0x01;
    img[9] = 7;
    img[10] = 0x19;
    // Manufacturing date, three little endian bytes, all distinct and non-zero
    // so a byte swap or a short write changes the rendered date.
    img[11] = 0x11;
    img[12] = 0x22;
    img[13] = 0x33;

    const fields = [_][]const u8{
        "ZigForge",
        "TransportBox",
        "SN-2468",
        "PN-1357",
        "FID-99",
    };
    var at: usize = 14;
    for (fields) |f| {
        img[at] = 0xc0 | @as(u8, f.len); // 8 bit ASCII, length f.len
        at += 1;
        @memcpy(img[at..][0..f.len], f);
        at += f.len;
    }
    img[at] = 0xc1; // no more fields
    img[63] = fruChecksum(img[8..63]);

    break :blk img;
};

/// The RMCP+ payload size is a little endian u16 at offset 0x0e.  Every other
/// case has a payload shorter than 256 bytes, so its high byte is always zero
/// and a transport that wrote — or read — only the low byte would be
/// indistinguishable from a correct one.  `lanplus/cipher1-raw-big` makes the
/// payload longer than 255 bytes in *both* directions so the high byte is
/// non-zero going out and coming back.
///
/// 250 request data bytes give a 257 byte message (7 + 250) and 249 response
/// data bytes give a 257 byte message (8 + 249).  Cipher suite 1 has no
/// confidentiality, so the fixture shows the bytes in the clear.
const big_request_data: [250]u8 = blk: {
    var d: [250]u8 = undefined;
    for (&d, 0..) |*x, i| x.* = @intCast(1 + (i * 7) % 255);
    break :blk d;
};

const big_response_data: [249]u8 = blk: {
    var d: [249]u8 = undefined;
    for (&d, 0..) |*x, i| x.* = @intCast(1 + (i * 11) % 255);
    break :blk d;
};

const big_args: [15 + big_request_data.len][]const u8 = blk: {
    @setEvalBranchQuota(100_000);
    const head = [_][]const u8{
        "-I",  "lanplus", "-H",   "127.0.0.1", "-p", "${port}",
        "-U",  user,      "-P",   pass,        "-C", "1",
        "raw", "0x2e",    "0x97",
    };
    var a: [15 + big_request_data.len][]const u8 = undefined;
    for (head, 0..) |h, i| a[i] = h;
    for (big_request_data, 0..) |v, i| {
        a[head.len + i] = std.fmt.comptimePrint("0x{x:0>2}", .{v});
    }
    const frozen = a;
    break :blk frozen;
};

pub const all: []const Case = &.{
    .{
        .name = "intf/unknown",
        .desc = "ipmi_intf_load rejects an unregistered interface name",
        .args = &.{ "-I", "no-such-intf", "mc", "info" },
        .timeout_ms = 10_000,
    },

    // -- IPMI v1.5 over LAN -------------------------------------------------

    .{
        .name = "lan/none-mc-info",
        .desc = "v1.5 session with authtype NONE, then Get Device ID",
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p", "${port}",
            "-U", "",    "-P", "",          "mc", "info",
        },
        .bmc = .{ .auth_types = 1 << 0, .extra = canned },
    },

    .{
        .name = "lan/md5-mc-info",
        .desc = "v1.5 session with an MD5 authcode on every packet",
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,  "-P", pass,        "mc", "info",
        },
        .bmc = .{ .username = user, .password = pass, .extra = canned },
    },

    .{
        .name = "lan/md5-raw-long",
        .desc = "v1.5 raw command whose data pins both checksum ranges",
        .args = &.{
            "-I",   "lan",  "-H",   "127.0.0.1", "-p",   "${port}",
            "-U",   user,   "-P",   pass,        "raw",  "0x2e",
            "0x91", "0x11", "0x22", "0x33",      "0x44", "0x55",
            "0x66", "0x77", "0x88", "0x99",      "0xaa", "0xbb",
            "0xcc", "0xdd", "0xee", "0xff",      "0x13", "0x37",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .extra = &.{.{ .netfn = 0x2e, .cmd = 0x91, .data = &.{ 0xde, 0xad, 0xbe, 0xef, 0x01 } }},
        },
    },

    .{
        .name = "lan/md5-raw-zeros",
        .desc = "v1.5 raw command with embedded NULs, pinning the length byte",
        .args = &.{
            "-I",   "lan",  "-H",   "127.0.0.1", "-p",   "${port}",
            "-U",   user,   "-P",   pass,        "raw",  "0x2e",
            "0x92", "0xa5", "0x00", "0x00",      "0x00", "0x00",
            "0x5a",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .extra = &.{.{ .netfn = 0x2e, .cmd = 0x92, .data = &.{ 0x00, 0x7f, 0x00 } }},
        },
    },

    .{
        .name = "lan/md5-raw-lun",
        .desc = "-l 7 puts a non-zero LUN in the low two bits of the netfn byte",
        .args = &.{
            "-I",  "lan",  "-H",   "127.0.0.1", "-p",   "${port}",
            "-U",  user,   "-P",   pass,        "-l",   "7",
            "raw", "0x2e", "0x96", "0x3c",      "0xa5", "0xc3",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .extra = &.{.{ .netfn = 0x2e, .cmd = 0x96, .data = &.{ 0x5c, 0xa3 } }},
        },
    },

    .{
        .name = "lan/none-retry",
        .desc = "v1.5 retransmission: three ignored datagrams, answered on the fourth try",
        .args = &.{
            "-I",  "lan",  "-H",   "127.0.0.1", "-p",   "${port}",
            "-U",  "",     "-P",   "",          "-N",   "1",
            "raw", "0x2e", "0x93", "0x41",      "0x42",
        },
        // No `-R`: the retry limit has to come from IPMI_LAN_RETRY, or a change
        // to it would not be observable here.
        .bmc = .{
            .auth_types = 1 << 0,
            .drop = &.{ 6, 7, 8 },
            .extra = &.{.{ .netfn = 0x2e, .cmd = 0x93, .data = &.{0x24} }},
        },
    },

    .{
        .name = "lan/none-timeout",
        .desc = "v1.5 command the BMC never answers: pins the retry limit exactly",
        .args = &.{
            "-I",  "lan",  "-H",   "127.0.0.1", "-p",   "${port}",
            "-U",  "",     "-P",   "",          "-N",   "1",
            "raw", "0x2e", "0x99", "0x51",      "0x52",
        },
        .bmc = .{
            .auth_types = 1 << 0,
            .deaf = .{ .netfn = 0x2e, .cmd = 0x99 },
        },
    },

    .{
        .name = "lan/none-ping-retry",
        .desc = "the RMCP presence ping is retried before the session starts",
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p", "${port}",
            "-U", "",    "-P", "",          "-N", "1",
            "-R", "3",   "mc", "info",
        },
        .bmc = .{ .auth_types = 1 << 0, .drop = &.{1}, .extra = canned },
    },

    .{
        .name = "lan/authcap-error",
        .desc = "session setup aborts on a Get Channel Auth Cap completion code",
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p", "${port}",
            "-U", "",    "-P", "",          "-N", "1",
            "-R", "1",   "mc", "info",
        },
        .bmc = .{ .auth_types = 1 << 0, .authcap_ccode = 0xd4 },
    },

    .{
        .name = "lan/activate-error",
        .desc = "session setup aborts on an Activate Session completion code",
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,  "-P", pass,        "-N", "1",
            "-R", "1",   "mc", "info",
        },
        .bmc = .{ .username = user, .password = pass, .activate_ccode = 0x81 },
    },

    .{
        .name = "lan/oem-supermicro",
        .desc = "-o supermicro skips the RMCP presence ping",
        .args = &.{
            "-I", "lan",  "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,   "-P", pass,        "-o", "supermicro",
            "mc", "info",
        },
        // `-o supermicro` selects authtype OEM (0x05), so the BMC has to
        // advertise it; the authcode then comes from `ipmi_auth_special`.
        .bmc = .{
            .username = user,
            .password = pass,
            .auth_types = (1 << 0) | (1 << 5),
            .extra = canned,
        },
    },

    .{
        .name = "lan/md5-chassis-status",
        .desc = "a non-App netfn over v1.5, exercising the netfn/lun packing",
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p",      "${port}",
            "-U", user,  "-P", pass,        "chassis", "status",
        },
        .bmc = .{ .username = user, .password = pass, .extra = canned },
    },

    .{
        .name = "lan/md5-bridged",
        .desc = "a bridged request: three checksum ranges and a Send Message wrapper",
        .args = &.{
            "-I",  "lan",  "-H",   "127.0.0.1", "-p",   "${port}",
            "-U",  user,   "-P",   pass,        "-t",   "0x82",
            "-b",  "6",    "-N",   "1",         "-R",   "1",
            "raw", "0x2e", "0x97", "0x11",      "0x22",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .extra = &.{
                device_id,
                chassis_status,
                .{ .netfn = 0x2e, .cmd = 0x97, .data = &.{ 0x71, 0x72, 0x73 } },
            },
        },
    },

    .{
        .name = "lan/md5-double-bridged",
        .desc = "a doubly bridged request: two nested Send Message wrappers",
        .args = &.{
            "-I",   "lan",  "-H",   "127.0.0.1", "-p",  "${port}",
            "-U",   user,   "-P",   pass,        "-t",  "0x82",
            "-b",   "6",    "-T",   "0x84",      "-B",  "7",
            "-N",   "1",    "-R",   "1",         "raw", "0x2e",
            "0x98", "0x33", "0x44",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .extra = &.{
                device_id,
                chassis_status,
                .{ .netfn = 0x2e, .cmd = 0x98, .data = &.{ 0x5e, 0x5f } },
            },
        },
    },

    // -- RMCP+ (lanplus) ----------------------------------------------------

    .{
        .name = "lanplus/cipher1-mc-info",
        .desc = "cipher suite 1: RAKP-HMAC-SHA1, no integrity, no confidentiality",
        .args = &.{
            "-I", "lanplus", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,      "-P", pass,        "-C", "1",
            "mc", "info",
        },
        .bmc = .{ .username = user, .password = pass, .extra = canned },
    },

    .{
        .name = "lanplus/cipher3-mc-info",
        .desc = "cipher suite 3: HMAC-SHA1-96 integrity and AES-CBC-128",
        .args = &.{
            "-I", "lanplus", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,      "-P", pass,        "-C", "3",
            "mc", "info",
        },
        .bmc = .{ .username = user, .password = pass, .extra = canned },
    },

    .{
        .name = "lanplus/cipher17-mc-info",
        .desc = "cipher suite 17: RAKP-HMAC-SHA256 and HMAC-SHA256-128",
        .args = &.{
            "-I", "lanplus", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,      "-P", pass,        "-C", "17",
            "mc", "info",
        },
        .bmc = .{ .username = user, .password = pass, .extra = canned },
    },

    .{
        .name = "lanplus/cipher3-kg",
        .desc = "two key login: the SIK is keyed with Kg instead of Kuid",
        .args = &.{
            "-I", "lanplus", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,      "-P", pass,        "-k", "bmc-key",
            "-C", "3",       "mc", "info",
        },
        .bmc = .{ .username = user, .password = pass, .kg = "bmc-key", .extra = canned },
    },

    .{
        .name = "lanplus/cipher1-raw-long",
        .desc = "RMCP+ payload assembly with a long raw command, unencrypted",
        .args = &.{
            "-I",   "lanplus", "-H",   "127.0.0.1", "-p",   "${port}",
            "-U",   user,      "-P",   pass,        "-C",   "1",
            "raw",  "0x2e",    "0x94", "0x11",      "0x22", "0x33",
            "0x44", "0x55",    "0x66", "0x77",      "0x88", "0x99",
            "0xaa", "0xbb",    "0xcc", "0xdd",      "0xee", "0xff",
            "0x13",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .extra = &.{.{ .netfn = 0x2e, .cmd = 0x94, .data = &.{ 0xc0, 0xff, 0xee } }},
        },
    },

    .{
        .name = "lanplus/cipher1-raw-big",
        .desc = "a payload over 255 bytes each way, pinning the u16 payload size",
        .args = &big_args,
        .bmc = .{
            .username = user,
            .password = pass,
            .extra = &.{.{ .netfn = 0x2e, .cmd = 0x97, .data = &big_response_data }},
        },
    },

    .{
        .name = "lanplus/cipher3-raw-pad",
        .desc = "confidentiality padding: a payload one byte short of a block",
        .args = &.{
            "-I",   "lanplus", "-H",   "127.0.0.1", "-p",   "${port}",
            "-U",   user,      "-P",   pass,        "-C",   "3",
            "raw",  "0x2e",    "0x95", "0x11",      "0x22", "0x33",
            "0x44", "0x55",    "0x66", "0x77",      "0x88",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .extra = &.{.{ .netfn = 0x2e, .cmd = 0x95, .data = &.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 } }},
        },
    },

    .{
        .name = "lanplus/cipher3-retry",
        .desc = "RMCP+ retransmission: the BMC ignores one datagram mid-session",
        .args = &.{
            "-I",   "lanplus", "-H",  "127.0.0.1", "-p",   "${port}",
            "-U",   user,      "-P",  pass,        "-C",   "3",
            "-N",   "1",       "raw", "0x2e",      "0x96", "0x41",
            "0x42",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .drop = &.{5},
            .extra = &.{.{ .netfn = 0x2e, .cmd = 0x96, .data = &.{0x24} }},
        },
    },

    .{
        .name = "lanplus/cipher3-timeout",
        .desc = "RMCP+ command the BMC never answers: pins the retry limit exactly",
        .args = &.{
            "-I",   "lanplus", "-H",  "127.0.0.1", "-p",   "${port}",
            "-U",   user,      "-P",  pass,        "-C",   "3",
            "-N",   "1",       "raw", "0x2e",      "0x9a", "0x51",
            "0x52",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .deaf = .{ .netfn = 0x2e, .cmd = 0x9a },
        },
    },

    .{
        .name = "lanplus/open-session-error",
        .desc = "the tool aborts when the Open Session Response carries a status",
        .args = &.{
            "-I", "lanplus", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,      "-P", pass,        "-C", "3",
            "-N", "1",       "-R", "1",         "mc", "info",
        },
        .bmc = .{ .username = user, .password = pass, .open_session_status = 0x01 },
    },

    .{
        .name = "lanplus/rakp2-error",
        .desc = "the tool aborts when RAKP 2 carries a non-zero status code",
        .args = &.{
            "-I", "lanplus", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,      "-P", pass,        "-C", "3",
            "-N", "1",       "-R", "1",         "mc", "info",
        },
        .bmc = .{ .username = user, .password = pass, .rakp2_status = 0x0d },
    },

    .{
        .name = "lanplus/rakp2-bad-authcode",
        .desc = "the tool rejects a RAKP 2 message whose authcode does not verify",
        .args = &.{
            "-I", "lanplus", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,      "-P", pass,        "-C", "3",
            "-N", "1",       "-R", "1",         "mc", "info",
        },
        .bmc = .{ .username = user, .password = pass, .corrupt_rakp2 = true },
    },

    .{
        .name = "lan/md5-long-creds",
        .desc = "credentials that fill both fixed size fields, pinning the truncation",
        .args = &.{
            "-I", "lan",     "-H", "127.0.0.1", "-p", "${port}",
            "-U", long_user, "-P", pass_16,     "mc", "info",
        },
        .bmc = .{ .username = long_user, .password = pass_16, .extra = canned },
    },

    .{
        .name = "lan/authtype-none-clears-password",
        .desc = "-A NONE clears the password, so MD5 is no longer eligible",
        // `IPMI_SESSION_AUTHTYPE_NONE` is zero, which is also the "caller did
        // not choose" value `ipmi_get_auth_capabilities_cmd()` tests for.  The
        // only thing keeping it out of the MD5 branch is that
        // `ipmi_intf_session_set_authtype()` zeroed the password first, so
        // dropping that clear turns this into a full MD5 session.
        .args = &.{
            "-I", "lan",  "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,   "-P", pass,        "-A", "NONE",
            "mc", "info",
        },
        .bmc = .{ .username = user, .password = pass, .extra = canned },
    },

    .{
        .name = "lan/md5-fru",
        .desc = "chunked FRU reads, pinning the unbridged maximum response size",
        // `read_fru_area()` sizes each Read FRU Data request from
        // `ipmi_intf_get_max_response_data_size()`, so the byte count in the
        // request is that function's return value minus two.
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p",  "${port}",
            "-U", user,  "-P", pass,        "fru", "print",
            "0",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .extra = canned,
            .fru = &fru_image,
        },
    },

    .{
        .name = "lan/md5-fru-bridged",
        .desc = "chunked FRU reads one bridge deep: the response size loses the wrapper",
        .args = &.{
            "-I", "lan", "-H",  "127.0.0.1", "-p", "${port}",
            "-U", user,  "-P",  pass,        "-t", "0x82",
            "-b", "6",   "fru", "print",     "0",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .extra = canned,
            .fru = &fru_image,
        },
    },

    .{
        .name = "lan/md5-fru-transit-channel",
        .desc = "double bridging selected by the transit channel alone, not the address",
        // `-T` names the same address as `-t`, so `transit_addr !=
        // target_addr` is false and only `transit_channel != target_channel`
        // can make `ipmi_intf_get_bridging_level()` answer 2.  Level 2 costs
        // another eight bytes of response budget, which changes every Read FRU
        // Data byte count on the wire.
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p",  "${port}",
            "-U", user,  "-P", pass,        "-t",  "0x82",
            "-b", "6",   "-T", "0x82",      "-B",  "7",
            "-N", "1",   "-R", "1",         "fru", "print",
            "0",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .extra = canned,
            .fru = &fru_image,
        },
    },

    // -- RMCP+ (lanplus) ----------------------------------------------------

    .{
        .name = "lanplus/cipher3-long-creds",
        .desc = "credentials that fill both fixed size fields, pinning the truncation",
        .args = &.{
            "-I", "lanplus", "-H", "127.0.0.1", "-p", "${port}",
            "-U", long_user, "-P", pass_20,     "-C", "3",
            "mc", "info",
        },
        // RAKP 1 carries the username length and the username itself, so the
        // 16 byte truncation is on the wire; the 20 byte password is the whole
        // RAKP HMAC key, so a short copy fails BMC side authcode verification
        // rather than merely diffing.
        .bmc = .{ .username = long_user, .password = pass_20, .extra = canned },
    },

    .{
        .name = "lan/none-privlvl-user",
        .desc = "-L USER stays at or below the default, so no Set Session Privilege Level is sent",
        .args = &.{
            "-I", "lan",  "-H", "127.0.0.1", "-p", "${port}",
            "-U", "",     "-P", "",          "-L", "USER",
            "mc", "info",
        },
        // `ipmi_set_session_privlvl_cmd` returns early when the requested level
        // is `<= IPMI_SESSION_PRIV_USER`.  The absence of a 0x3b datagram is
        // what pins both the comparison and the constant: widening it to `<`
        // adds a datagram, narrowing the constant to OPERATOR removes one from
        // the other cases.
        .bmc = .{ .auth_types = 1 << 0, .extra = canned },
    },

    .{
        .name = "lan/none-authtype-unsupported",
        .desc = "-A MD5 against a BMC that only advertises NONE",
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,  "-P", pass,        "-A", "MD5",
            "-N", "1",   "-R", "1",         "mc", "info",
        },
        .bmc = .{ .username = user, .password = pass, .auth_types = 1 << 0 },
    },

    .{
        .name = "lan/none-challenge-error",
        .desc = "Get Session Challenge answered 0x81, the named 'Invalid user name' path",
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p", "${port}",
            "-U", "",    "-P", "",          "-N", "1",
            "-R", "1",   "mc", "info",
        },
        .bmc = .{ .auth_types = 1 << 0, .challenge_ccode = 0x81 },
    },

    .{
        .name = "lan/md5-privlvl-error",
        .desc = "Set Session Privilege Level fails, so the session just opened is closed again",
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,  "-P", pass,        "-N", "1",
            "-R", "1",   "mc", "info",
        },
        // Two Close Session datagrams are expected: one from the `close_fail`
        // label in `ipmi_lan_activate_session`, and one from `ipmi_lan_close`,
        // which runs because `intf->abort` was already cleared by Activate
        // Session and `intf->session->active` is still set.
        .bmc = .{ .username = user, .password = pass, .privlvl_ccode = 0x81 },
    },

    .{
        .name = "lan/md5-close-error",
        .desc = "Close Session answered 0x87, which renders the session id in the message",
        .args = &.{
            "-I", "lan", "-H", "127.0.0.1", "-p", "${port}",
            "-U", user,  "-P", pass,        "-N", "1",
            "-R", "1",   "mc", "info",
        },
        .bmc = .{
            .username = user,
            .password = pass,
            .close_ccode = 0x87,
            .extra = canned,
        },
    },

    .{
        .name = "lan/none-dup-request",
        .desc = "a 0xCF Duplicate Request response is discarded and the command retried",
        .args = &.{
            "-I",  "lan",  "-H",   "127.0.0.1", "-p",   "${port}",
            "-U",  "",     "-P",   "",          "-N",   "1",
            "raw", "0x2e", "0x9a", "0x61",      "0x62",
        },
        // `ipmi_lan_send_cmd` throws the 0xCF away and polls again; nothing
        // arrives, so the retry loop retransmits and the second attempt is
        // answered normally.  The retransmission reuses `rq_seq`, which is what
        // distinguishes this from an ordinary drop.
        .bmc = .{
            .auth_types = 1 << 0,
            .dup_once = .{ .netfn = 0x2e, .cmd = 0x9a },
            .extra = &.{.{ .netfn = 0x2e, .cmd = 0x9a, .data = &.{ 0x37, 0x48 } }},
        },
    },

    .{
        .name = "lan/none-intelwv2",
        .desc = "-o intelwv2 sends a 16 byte thump after the ping and a 10 byte thump after every request",
        .args = &.{
            "-I",  "lan",  "-H",   "127.0.0.1", "-p",   "${port}",
            "-U",  "",     "-P",   "",          "-o",   "intelwv2",
            "raw", "0x2e", "0x9b", "0x71",      "0x72",
        },
        // The thump datagrams are not RMCP, so the model BMC has to be told to
        // ignore them rather than report them; their bytes are still pinned.
        .bmc = .{
            .auth_types = 1 << 0,
            .tolerate_junk = true,
            .extra = &.{.{ .netfn = 0x2e, .cmd = 0x9b, .data = &.{ 0x83, 0x94 } }},
        },
    },

    // -- RMCP+ (lanplus) ----------------------------------------------------
};
