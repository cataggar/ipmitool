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

pub const all: []const Case = &.{
    // -- ipmi_intf registry -------------------------------------------------
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
};
