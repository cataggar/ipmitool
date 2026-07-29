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
//! searching for the string will be looking at.  One detail is not reproduced:
//! glibc prefixes the line with the program name, which it reads out of a
//! non-portable global that neither Zig nor ipmitool exposes.

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

fn fail(comptime site: Site) noreturn {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "{s}:{d}: {s}: Assertion `{s}' failed.\n",
        .{ site.file, site.line, site.func, site.expr },
    ) catch &buffer;
    var written: usize = 0;
    while (written < message.len) {
        const n = std.c.write(2, message.ptr + written, message.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
    std.c.abort();
}
