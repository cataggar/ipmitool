//! Just enough of the C to link `intf/open.zig` into the unit-test binary.
//!
//! `zig build test` compiles `src/zig/root.zig` against libc alone, so the two
//! C symbols the `open` transport reaches for -- `lperror()` from `lib/log.c`
//! and `ipmi_get_oem()` from `lib/ipmi_sel.c` -- have no definition there.
//! Without these the transport could only be tested by reimplementing it,
//! which pins nothing.
//!
//! Deliberately disjoint from `crypto/test_stubs.zig`: that file already
//! defines `verbose`, `lprintf`, `printbuf`, `buf2str` and `ipmi_oem_active`
//! for the same binary, and two strong definitions of one symbol would not
//! link.

const builtin = @import("builtin");

comptime {
    if (!builtin.is_test) @compileError("test_stubs.zig is for the test binary only");
}

/// What `ipmi_get_oem()` should answer.  A test sets this and then checks that
/// the value reached `intf->manufacturer_id`, which is the only way to tell
/// that `open()` asked at all.
pub var oem: c_uint = 0;

/// How many times `ipmi_get_oem()` was called.
pub var oem_calls: usize = 0;

comptime {
    @export(&lperror, .{ .name = "lperror", .linkage = .strong });
    @export(&ipmiGetOem, .{ .name = "ipmi_get_oem", .linkage = .strong });
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
