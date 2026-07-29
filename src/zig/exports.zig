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
    // `util/` modules are also imported by `src/zig/root.zig` for their types
    // and by other ports, so their `@export` calls cannot sit at file scope:
    // they would collide with the C translation unit whenever a *different*
    // module is the one selected.  Each port gathers them in `exportSymbols()`
    // instead, and this is the only place that calls it.
    if (selected("log")) {
        @import("util/log.zig").exportSymbols();
    }
    if (selected("helper")) {
        @import("util/helper.zig").exportSymbols();
    }
    if (selected("channel")) {
        @import("cmd/channel.zig").exportSymbols();
    }
    if (selected("user")) {
        @import("cmd/user.zig").exportSymbols();
    }
    if (selected("time")) {
        @import("util/time.zig").exportSymbols();
    }
    if (selected("md5")) {
        _ = @import("crypto/md5.zig");
    }
    if (selected("auth")) {
        _ = @import("crypto/auth.zig");
    }
    if (selected("lanplus-crypt-impl")) {
        _ = @import("crypto/lanplus_crypt_impl.zig");
    }
    if (selected("lanplus-crypt")) {
        _ = @import("crypto/lanplus_crypt.zig");
    }
    if (selected("raw")) {
        @import("cmd/raw.zig").exportSymbols();
    }
    if (selected("mc")) {
        @import("cmd/mc.zig").exportSymbols();
    }
    if (selected("chassis")) {
        @import("cmd/chassis.zig").exportSymbols();
    }
    if (selected("event")) {
        @import("cmd/event.zig").exportSymbols();
    }
    if (selected("sensor")) {
        @import("cmd/sensor.zig").exportSymbols();
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
