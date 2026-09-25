//! Port of `src/plugins/lanplus/lanplus_dump.c`: the `-vv` packet dump for the
//! three RMCP+ session-setup responses.
//!
//! Everything here is `printf`, gated on `verbose < 2`.  The output is
//! reproduced byte for byte, including two upstream quirks worth naming so they
//! are not mistaken for typos introduced by the port:
//!
//!  * "Negotiated authenticatin algorithm" is misspelled upstream.
//!  * The label column is not consistent between the arms of the key-exchange
//!    switch: the `none` and `invalid` arms in `lanplus_dump_rakp2_message()`
//!    pad to one width, the `sha1`/`md5` arms to another, and `sha256` to a
//!    third.  `lanplus_dump_rakp4_message()` pads its `none` arm differently
//!    again.  All four widths are preserved exactly.

const builtin = @import("builtin");
const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const stdout_io = @import("../util/stdout.zig");

/// `DUMP_PREFIX_INCOMING`.
const in_prefix = "<<";

/// `HAVE_CRYPTO_SHA256`.
const have_sha256 = @hasDecl(c, "HAVE_CRYPTO_SHA256");

const sha1_authcode_size = 12;
const hmac_md5_authcode_size = 16;
const hmac_sha256_authcode_size = 16;
const sha_digest_length = 20;
const md5_digest_length = 16;
const sha256_digest_length = 32;

const rakp_status_no_errors = 0x00;

fn dumpOpenSessionResponse(rsp: *const ipmi.Response) callconv(.c) void {
    if (c.verbose < 2) return;
    emitDump("lanplus_dump_open_session_response", rsp, 0, writeOpenSessionResponse);
}

fn dumpRakp2Message(rsp: *const ipmi.Response, auth_alg: u8) callconv(.c) void {
    if (c.verbose < 2) return;
    emitDump("lanplus_dump_rakp2_message", rsp, auth_alg, writeRakp2Message);
}

fn dumpRakp4Message(rsp: *const ipmi.Response, auth_alg: u8) callconv(.c) void {
    if (c.verbose < 2) return;
    emitDump("lanplus_dump_rakp4_message", rsp, auth_alg, writeRakp4Message);
}

fn emitDump(
    comptime context: []const u8,
    rsp: *const ipmi.Response,
    auth_alg: u8,
    comptime format: anytype,
) void {
    stdout_io.syncC(context);
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    format(&stdout.interface, rsp, auth_alg) catch
        std.debug.panic("{s}: stdout write failed: {t}", .{ context, stdout.err orelse error.WriteFailed });
    stdout.interface.flush() catch
        std.debug.panic("{s}: stdout flush failed: {t}", .{ context, stdout.err orelse error.WriteFailed });
}

fn writeOpenSessionResponse(writer: *std.Io.Writer, rsp: *const ipmi.Response, _: u8) std.Io.Writer.Error!void {
    const p = &rsp.payload.open_session_response;

    try stdout_io.write(writer, "{s}OPEN SESSION RESPONSE\n", .{in_prefix});
    try stdout_io.write(writer, "{s}  Message tag                        : 0x{x:0>2}\n", .{ in_prefix, p.message_tag });
    try stdout_io.write(writer, "{s}  RMCP+ status                       : {s}\n", .{
        in_prefix, std.mem.span(c.val2str(p.rakp_return_code, c.ipmi_rakp_return_codes)),
    });
    try stdout_io.write(writer, "{s}  Maximum privilege level            : {s}\n", .{
        in_prefix, std.mem.span(c.val2str(p.max_priv_level, c.ipmi_priv_levels)),
    });
    try stdout_io.write(writer, "{s}  Console Session ID                 : 0x{x:0>8}\n", .{ in_prefix, p.console_id });

    // Only tag, status, privlvl and console id are returned on error.
    if (p.rakp_return_code != rakp_status_no_errors) return;

    try stdout_io.write(writer, "{s}  BMC Session ID                     : 0x{x:0>8}\n", .{ in_prefix, p.bmc_id });
    try stdout_io.write(writer, "{s}  Negotiated authenticatin algorithm : {s}\n", .{
        in_prefix, std.mem.span(c.val2str(p.auth_alg, c.ipmi_auth_algorithms)),
    });
    try stdout_io.write(writer, "{s}  Negotiated integrity algorithm     : {s}\n", .{
        in_prefix, std.mem.span(c.val2str(p.integrity_alg, c.ipmi_integrity_algorithms)),
    });
    try stdout_io.write(writer, "{s}  Negotiated encryption algorithm    : {s}\n\n", .{
        in_prefix, std.mem.span(c.val2str(p.crypt_alg, c.ipmi_encryption_algorithms)),
    });
}

fn writeHex(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    for (bytes) |byte| try stdout_io.write(writer, "{x:0>2}", .{byte});
}

fn writeRakp2Message(writer: *std.Io.Writer, rsp: *const ipmi.Response, auth_alg: u8) std.Io.Writer.Error!void {
    const p = &rsp.payload.rakp2_message;

    try stdout_io.write(writer, "{s}RAKP 2 MESSAGE\n", .{in_prefix});
    try stdout_io.write(writer, "{s}  Message tag                   : 0x{x:0>2}\n", .{ in_prefix, p.message_tag });
    try stdout_io.write(writer, "{s}  RMCP+ status                  : {s}\n", .{
        in_prefix, std.mem.span(c.val2str(p.rakp_return_code, c.ipmi_rakp_return_codes)),
    });
    try stdout_io.write(writer, "{s}  Console Session ID            : 0x{x:0>8}\n", .{ in_prefix, p.console_id });
    try stdout_io.write(writer, "{s}  BMC random number             : 0x", .{in_prefix});
    try writeHex(writer, p.bmc_rand[0..16]);
    try stdout_io.write(writer, "\n{s}  BMC GUID                      : 0x", .{in_prefix});
    try writeHex(writer, p.bmc_guid[0..16]);
    try stdout_io.write(writer, "\n", .{});

    switch (auth_alg) {
        c.IPMI_AUTH_RAKP_NONE => try stdout_io.write(writer, "{s}  Key exchange auth code         : none\n", .{in_prefix}),
        c.IPMI_AUTH_RAKP_HMAC_SHA1 => {
            try stdout_io.write(writer, "{s}  Key exchange auth code [sha1] : 0x", .{in_prefix});
            try writeHex(writer, p.key_exchange_auth_code[0..sha_digest_length]);
            try stdout_io.write(writer, "\n", .{});
        },
        c.IPMI_AUTH_RAKP_HMAC_MD5 => {
            try stdout_io.write(writer, "{s}  Key exchange auth code [md5]   : 0x", .{in_prefix});
            try writeHex(writer, p.key_exchange_auth_code[0..md5_digest_length]);
            try stdout_io.write(writer, "\n", .{});
        },
        else => blk: {
            if (have_sha256 and auth_alg == c.IPMI_AUTH_RAKP_HMAC_SHA256) {
                try stdout_io.write(writer, "{s}  Key exchange auth code [sha256]: 0x", .{in_prefix});
                try writeHex(writer, p.key_exchange_auth_code[0..sha256_digest_length]);
                try stdout_io.write(writer, "\n", .{});
                break :blk;
            }
            try stdout_io.write(writer, "{s}  Key exchange auth code         : invalid", .{in_prefix});
        },
    }
    try stdout_io.write(writer, "\n", .{});
}

fn writeRakp4Message(writer: *std.Io.Writer, rsp: *const ipmi.Response, auth_alg: u8) std.Io.Writer.Error!void {
    const p = &rsp.payload.rakp4_message;

    try stdout_io.write(writer, "{s}RAKP 4 MESSAGE\n", .{in_prefix});
    try stdout_io.write(writer, "{s}  Message tag                   : 0x{x:0>2}\n", .{ in_prefix, p.message_tag });
    try stdout_io.write(writer, "{s}  RMCP+ status                  : {s}\n", .{
        in_prefix, std.mem.span(c.val2str(p.rakp_return_code, c.ipmi_rakp_return_codes)),
    });
    try stdout_io.write(writer, "{s}  Console Session ID            : 0x{x:0>8}\n", .{ in_prefix, p.console_id });

    switch (auth_alg) {
        c.IPMI_AUTH_RAKP_NONE => try stdout_io.write(writer, "{s}  Key exchange auth code        : none\n", .{in_prefix}),
        c.IPMI_AUTH_RAKP_HMAC_SHA1 => {
            try stdout_io.write(writer, "{s}  Key exchange auth code [sha1] : 0x", .{in_prefix});
            try writeHex(writer, p.integrity_check_value[0..sha1_authcode_size]);
            try stdout_io.write(writer, "\n", .{});
        },
        c.IPMI_AUTH_RAKP_HMAC_MD5 => {
            try stdout_io.write(writer, "{s}  Key exchange auth code [md5]   : 0x", .{in_prefix});
            try writeHex(writer, p.integrity_check_value[0..hmac_md5_authcode_size]);
            try stdout_io.write(writer, "\n", .{});
        },
        else => blk: {
            if (have_sha256 and auth_alg == c.IPMI_AUTH_RAKP_HMAC_SHA256) {
                try stdout_io.write(writer, "{s}  Key exchange auth code [sha256]: 0x", .{in_prefix});
                try writeHex(writer, p.integrity_check_value[0..hmac_sha256_authcode_size]);
                try stdout_io.write(writer, "\n", .{});
                break :blk;
            }
            try stdout_io.write(writer, "{s}  Key exchange auth code         : invalid", .{in_prefix});
        },
    }
    try stdout_io.write(writer, "\n", .{});
}

comptime {
    // `val2str()` and the `valstr` tables live in C; `intf/test_stubs.zig`
    // supplies them for the test binary only.
    if (builtin.is_test) _ = @import("test_stubs.zig");
}

pub fn exportSymbols() void {
    // The all-Zig comparison build selects this port even when the lanplus
    // interface (and its C-only lookup tables) is disabled.
    if (!@hasDecl(c, "IPMI_INTF_LANPLUS")) return;

    abi.assertCallSignature(@TypeOf(dumpOpenSessionResponse), @TypeOf(c.lanplus_dump_open_session_response));
    abi.assertCallSignature(@TypeOf(dumpRakp2Message), @TypeOf(c.lanplus_dump_rakp2_message));
    abi.assertCallSignature(@TypeOf(dumpRakp4Message), @TypeOf(c.lanplus_dump_rakp4_message));

    @export(&dumpOpenSessionResponse, .{ .name = "lanplus_dump_open_session_response" });
    @export(&dumpRakp2Message, .{ .name = "lanplus_dump_rakp2_message" });
    @export(&dumpRakp4Message, .{ .name = "lanplus_dump_rakp4_message" });
}

test "dump stdout propagates failures at the first line and inside a hex field" {
    var rsp = std.mem.zeroes(ipmi.Response);
    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeOpenSessionResponse(&failing, &rsp, 0));
    try std.testing.expectError(error.WriteFailed, writeRakp2Message(&failing, &rsp, c.IPMI_AUTH_RAKP_HMAC_SHA1));
    try std.testing.expectError(error.WriteFailed, writeRakp4Message(&failing, &rsp, c.IPMI_AUTH_RAKP_HMAC_SHA1));

    const first_line = "<<RAKP 2 MESSAGE\n";
    var storage: [first_line.len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.WriteFailed, writeRakp2Message(&writer, &rsp, c.IPMI_AUTH_RAKP_HMAC_SHA1));
    try std.testing.expectEqualStrings(first_line, writer.buffered());

    var hex_storage: [1]u8 = undefined;
    var hex_writer = std.Io.Writer.fixed(&hex_storage);
    try std.testing.expectError(error.WriteFailed, writeHex(&hex_writer, &.{0xff}));
}

test {
    std.testing.refAllDecls(@This());
}
