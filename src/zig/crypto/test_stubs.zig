//! Just enough of the C to link `lanplus_crypt.zig` and
//! `lanplus_crypt_impl.zig` into the unit-test binary.
//!
//! Without this the ported wrappers are untestable in isolation — they call
//! `lprintf`, `printbuf`, `ipmi_oem_active` and read `verbose`, none of which
//! exist outside a full ipmitool link — so the tests could only ever
//! *re-implement* what the wrappers do and compare that against the fixtures.
//! That leaves every constant living solely in a wrapper unpinned: a wrong
//! comparison length or packet offset there is invisible, because no test
//! executes the line it is on.
//!
//! Linking the real functions instead means the vectors drive the same code
//! the binary ships.  Only compiled when `builtin.is_test`.

const builtin = @import("builtin");
const std = @import("std");

comptime {
    // Belt and braces: these are strong definitions of symbols the real binary
    // gets from C, so they must never reach a non-test link.
    if (!builtin.is_test) @compileError("test_stubs.zig is for the test binary only");
}

/// `extern int verbose` — left at 0 so the wrappers take their quiet paths and
/// the `printbuf` calls below are never reached.
export var verbose: c_int = 0;

/// What `ipmi_oem_active` should answer.  Tests set this around a call.
pub var active_oem: []const u8 = "";

comptime {
    @export(&printbuf, .{ .name = "printbuf", .linkage = .strong });
    @export(&lprintf, .{ .name = "lprintf", .linkage = .strong });
    @export(&ipmiOemActive, .{ .name = "ipmi_oem_active", .linkage = .strong });
    @export(&buf2str, .{ .name = "buf2str", .linkage = .strong });
}

fn printbuf(buf: [*c]const u8, len: c_int, desc: [*c]const u8) callconv(.c) void {
    _ = buf;
    _ = len;
    _ = desc;
}

/// Variadic, and deliberately never reads its arguments: `@cVaStart` is a
/// compile error on aarch64 in Zig 0.16, but a definition that ignores the
/// list is fine.
fn lprintf(level: c_int, format: [*c]const u8, ...) callconv(.c) void {
    _ = level;
    _ = format;
}

/// Only reached from `verbose > 3` logging, which the stub `verbose` disables.
fn buf2str(buf: [*c]const u8, len: c_int) callconv(.c) [*c]const u8 {
    _ = buf;
    _ = len;
    return "";
}

fn ipmiOemActive(intf: ?*anyopaque, name: [*c]const u8) callconv(.c) c_int {
    _ = intf;
    if (active_oem.len == 0) return 0;
    return @intFromBool(std.mem.eql(u8, std.mem.sliceTo(name, 0), active_oem));
}
