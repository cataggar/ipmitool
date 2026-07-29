//! Link-time root of the Zig replacement library.
//!
//! `build.zig` compiles this file into `libipmitool_zig.a` and drops the
//! matching `.c` files from the C compile, so the symbols a selected module
//! `@export`s are the ones the remaining C links against.
//!
//! Each entry below is guarded by `-Dzig-modules=<name>`: when the name is not
//! selected the `@import` is never analysed, nothing is exported, and the C
//! translation unit stays in the build.  Adding a port is one line here plus one
//! entry in the `zig_modules` table in `build.zig`.

const std = @import("std");

const selection = @import("build_options").zig_modules;

comptime {
    if (selected("oem")) {
        _ = @import("cmd/oem.zig");
    }
    if (selected("strings")) {
        // Two files: the lookup tables, and the IANA PEN registry loader that
        // only `exports.zig` may pull in because it calls back into `log.c`.
        _ = @import("util/strings.zig");
        _ = @import("util/strings_registry.zig");
    }
}

fn selected(comptime name: []const u8) bool {
    comptime {
        for (selection) |module| {
            if (std.mem.eql(u8, module, name)) return true;
        }
        return false;
    }
}
