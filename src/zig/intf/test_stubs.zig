//! Just enough of the C to link `intf/` transports into the unit-test binary.
//!
//! `zig build test` compiles `src/zig/root.zig` against libc alone, so the C
//! symbols the transports reach for -- `lperror()` from `lib/log.c`,
//! `ipmi_get_oem()` from `lib/ipmi_sel.c` and `val2str()` from `lib/helper.c`
//! -- have no definition there.  Without these the transports could only be
//! tested by reimplementing them, which pins nothing.
//!
//! `ipmi_auth_md5()` and `ipmi_auth_md2()` are deliberately *not* stubbed:
//! `crypto/auth.zig` already exports them into this binary, and `build_cmd`'s
//! tests use the real ones as an oracle for which slice of the packet the
//! authcode is computed over.
//!
//! Deliberately disjoint from `crypto/test_stubs.zig`: that file already
//! defines `verbose`, `lprintf`, `printbuf`, `buf2str` and `ipmi_oem_active`
//! for the same binary, and two strong definitions of one symbol would not
//! link.

const builtin = @import("builtin");
const std = @import("std");

comptime {
    if (!builtin.is_test) @compileError("test_stubs.zig is for the test binary only");
}

/// What `ipmi_get_oem()` should answer.  A test sets this and then checks that
/// the value reached `intf->manufacturer_id`, which is the only way to tell
/// that a transport asked at all.
pub var oem: c_uint = 0;

/// How many times `ipmi_get_oem()` was called.
pub var oem_calls: usize = 0;

comptime {
    @export(&lperror, .{ .name = "lperror", .linkage = .strong });
    @export(&ipmiGetOem, .{ .name = "ipmi_get_oem", .linkage = .strong });
    @export(&val2str, .{ .name = "val2str", .linkage = .strong });
    @export(&ipmiCsum, .{ .name = "ipmi_csum", .linkage = .strong });
}

/// `ipmi_csum()` is not a stub in the usual sense.  The transports call it
/// through the bridge, the same way every other ported module calls
/// `buf2str()` or `str2uchar()`, so that a `-Dzig-modules=...` binary has
/// exactly one checksum in it and the transport fixtures keep their grip on
/// it.  `lib/helper.c` is not linked into the unit-test binary, so the symbol
/// is forwarded to the audited Zig port instead of being reimplemented here.
/// It cannot launder anything either way: the unit tests' expected checksums
/// are hand-computed literals and the fixtures were recorded from the C.
fn ipmiCsum(d: [*c]const u8, s: c_int) callconv(.c) u8 {
    return @import("../util/helper.zig").ipmiCsum(d, s);
}

/// Variadic and deliberately never reads its arguments: `@cVaStart` is a
/// compile error on aarch64 in Zig 0.16, but a definition that ignores the list
/// is fine.  It writes nothing, because `zig build test` treats any output on
/// stderr as a failure.
fn lperror(level: c_int, format: [*c]const u8, ...) callconv(.c) void {
    _ = level;
    _ = format;
}

fn ipmiGetOem(intf: ?*anyopaque) callconv(.c) c_uint {
    _ = intf;
    oem_calls += 1;
    return oem;
}

/// Only ever reached from the `LOG_DEBUG+1` packet dumps, which the stub
/// `verbose` above disables -- but the *arguments* are still evaluated, so the
/// symbol has to exist.
fn val2str(val: u16, vs: ?*const anyopaque) callconv(.c) [*c]const u8 {
    _ = val;
    _ = vs;
    return "";
}

/// The three functions `lan.zig` reaches for only from `open()` and `close()`,
/// neither of which any unit test calls -- they open a real socket.  The
/// definitions exist so the module links; a test that reached one would get an
/// obviously wrong answer rather than a plausible one.
pub var socket_connect_result: c_int = -1;
pub var session_cleanup_calls: usize = 0;

comptime {
    @export(&ipmiIntfSessionCleanup, .{
        .name = "ipmi_intf_session_cleanup",
        .linkage = .strong,
    });
    @export(&ipmiIntfSocketConnect, .{
        .name = "ipmi_intf_socket_connect",
        .linkage = .strong,
    });
    @export(&hpm2DetectMaxPayloadSize, .{
        .name = "hpm2_detect_max_payload_size",
        .linkage = .strong,
    });
}

fn ipmiIntfSessionCleanup(intf: ?*anyopaque) callconv(.c) void {
    _ = intf;
    session_cleanup_calls += 1;
}

fn ipmiIntfSocketConnect(intf: ?*anyopaque) callconv(.c) c_int {
    _ = intf;
    return socket_connect_result;
}

fn hpm2DetectMaxPayloadSize(intf: ?*anyopaque) callconv(.c) c_int {
    _ = intf;
    return -1;
}

// ---------------------------------------------------------------------------
// lanplus extras
// ---------------------------------------------------------------------------
//
// `src/plugins/lanplus/lanplus_strings.c` stays C, so its two tables have no
// definition in this binary.  Everything else `lanplus.zig` looks up --
// `completion_code_vals`, `ipmi_privlvl_vals`, `ipmi_authtype_session_vals`,
// `ipmi_auth_algorithms`, `ipmi_integrity_algorithms` and
// `ipmi_encryption_algorithms` -- comes from `util/strings_tables.zig`, which
// `root.zig` already pulls in, so stubbing those here would be a duplicate
// definition.

/// `struct valstr`.  Declared locally rather than imported from the bridge so
/// this file stays free of `ipmi_c`, like the rest of `test_stubs.zig`.
const ValStr = extern struct {
    val: u32,
    str: ?[*:0]const u8,
};

var rakp_return_codes = [_]ValStr{.{ .val = 0, .str = null }};
var priv_levels = [_]ValStr{.{ .val = 0, .str = null }};

/// What `ipmi_get_channel_cipher_suites()` should answer.
pub var cipher_suites_result: c_int = -1;

/// How many times `ipmi_intf_session_set_cipher_suite_id()` was called, and
/// with what.  `open()` is the only caller and no unit test reaches it, but a
/// test that did would see the effect rather than a plausible-looking nothing.
pub var set_cipher_suite_calls: usize = 0;
pub var set_cipher_suite_last: c_uint = 0;

comptime {
    @export(&rakp_return_codes, .{ .name = "ipmi_rakp_return_codes", .linkage = .strong });
    @export(&priv_levels, .{ .name = "ipmi_priv_levels", .linkage = .strong });
    @export(&ipmiGetChannelCipherSuites, .{
        .name = "ipmi_get_channel_cipher_suites",
        .linkage = .strong,
    });
    @export(&ipmiIntfSessionSetCipherSuiteId, .{
        .name = "ipmi_intf_session_set_cipher_suite_id",
        .linkage = .strong,
    });
}

fn ipmiGetChannelCipherSuites(
    intf: ?*anyopaque,
    payload_type: [*c]const u8,
    channel: u8,
    suites: ?*anyopaque,
    count: *usize,
) callconv(.c) c_int {
    _ = intf;
    _ = payload_type;
    _ = channel;
    _ = suites;
    count.* = 0;
    return cipher_suites_result;
}

fn ipmiIntfSessionSetCipherSuiteId(intf: ?*anyopaque, id: c_uint) callconv(.c) void {
    _ = intf;
    set_cipher_suite_calls += 1;
    set_cipher_suite_last = id;
}
