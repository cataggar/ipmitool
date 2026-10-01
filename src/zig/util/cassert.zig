//! `<assert.h>` parity for ported translation units.
//!
//! The C crypto code guards its "cannot happen" branches with `assert()`, and
//! several of them are reachable from a misbehaving BMC rather than from a bug:
//! `lanplus_decrypt_payload` aborts on malformed confidentiality padding, for
//! instance.  A port that turned those into a Zig panic would change both the
//! exit status and the diagnostic, so this reproduces what glibc does instead:
//! the same one line on stderr, then `SIGABRT`.
//!
//! The file, line, function and expression are passed in from the call site so
//! the message names the C source the port replaced, which is what a user
//! searching for the string will be looking at.
//!
//! Two details are approximations rather than reproductions, because there is
//! no single right answer to reproduce:
//!
//!   * glibc prefixes the line with the program name, which it reads out of a
//!     non-portable global that neither Zig nor ipmitool exposes.
//!   * gcc and clang disagree on what `__LINE__` and `__func__` expand to
//!     inside a multi-line `assert()`.  gcc reports the line the `assert`
//!     *opens* on and the bare function name; clang (and therefore `zig cc`)
//!     reports the line the closing paren is on and the full prototype.  They
//!     also disagree on `__FILE__`, since autotools compiles from inside the
//!     source directory and gets a bare basename while `zig build` passes an
//!     absolute path.  The `Site` values in the ported modules follow the gcc
//!     convention with a repo-relative path.
//!
//! What *is* byte-exact is the assertion expression, so that is the part
//! `src/zig/crypto/vectors_test.zig` pins against the captured C output.  See
//! `doc/zig-migration/crypto.md`.

const std = @import("std");

/// Where a C `assert()` sat in the file this module replaces.
pub const Site = struct {
    /// Path as it appears in the C build, e.g. `src/plugins/lanplus/...`.
    file: []const u8,
    line: u32,
    /// Enclosing C function.
    func: []const u8,
    /// The expression as written in the C.
    expr: []const u8,
};

/// `assert(condition)`.
pub fn expect(condition: bool, comptime site: Site) void {
    if (condition) return;
    fail(site);
}

/// `assert(0)`: the branch the C considers unreachable.
pub fn unreachableBranch(comptime site: Site) noreturn {
    fail(site);
}

fn writeFailure(writer: *std.Io.Writer, comptime site: Site) std.Io.Writer.Error!void {
    try writer.print(
        "{s}:{d}: {s}: Assertion `{s}' failed.\n",
        .{ site.file, site.line, site.func, site.expr },
    );
}

fn fail(comptime site: Site) noreturn {
    var stderr = std.Io.File.stderr().writerStreaming(std.Options.debug_io, &.{});
    writeFailure(&stderr.interface, site) catch std.process.abort();
    stderr.interface.flush() catch std.process.abort();
    std.process.abort();
}

test "assertion diagnostic preserves the expression and propagates writer failure" {
    const site: Site = .{
        .file = "assertion.c",
        .line = 42,
        .func = "fixture",
        .expr = "expression",
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeFailure(&writer, site);
    try std.testing.expectEqualStrings(
        "assertion.c:42: fixture: Assertion `expression' failed.\n",
        writer.buffered(),
    );
    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeFailure(&failing, site));
    expect(true, site);
}

test "assertion diagnostic is not limited to an uninitialized fixed-size fallback" {
    const site: Site = .{
        .file = "assertion.c",
        .line = 42,
        .func = "fixture",
        .expr = "x" ** 1024,
    };
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeFailure(&writer, site);
    try std.testing.expectEqualStrings(
        "assertion.c:42: fixture: Assertion `" ++ ("x" ** 1024) ++ "' failed.\n",
        writer.buffered(),
    );
}
