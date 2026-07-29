//! Namespace for the Zig side of the migration.
//!
//! Importing this file pulls in every header port and therefore every
//! `comptime` ABI assertion, which is what `zig build test` compiles.  It
//! deliberately does *not* reach into `cmd/`: those modules `@export` C symbols
//! and are only ever linked through `exports.zig`.
//!
//! Layout, mirroring the C tree:
//!
//! | Zig            | C                                        |
//! | -------------- | ---------------------------------------- |
//! | `core/`        | `include/ipmitool/ipmi*.h` data types     |
//! | `intf/`        | `ipmi_intf.h` and `src/plugins/*`         |
//! | `cmd/`         | one module per `lib/ipmi_*.c`             |
//! | `util/`        | `helper.c`, `log.c`, `bswap.h`, time      |
//!
//! See doc/zig-migration/interop-seams.md.

const std = @import("std");

/// Comptime ABI parity helpers used by every header port.
pub const abi = @import("abi.zig");

/// Ports of the core IPMI data types.
pub const core = struct {
    pub const ipmi = @import("core/ipmi.zig");
    pub const oem = @import("core/oem.zig");
};

/// Ports of the transport interface.
pub const intf = struct {
    pub const ipmi_intf = @import("intf/intf.zig");
};

/// Ports of the shared utilities.
pub const util = struct {
    pub const bswap = @import("util/bswap.zig");
    pub const helper = @import("util/helper.zig");
    pub const log = @import("util/log.zig");
    pub const strings = @import("util/strings.zig");
    pub const time = @import("util/time.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(core);
    std.testing.refAllDecls(intf);
    std.testing.refAllDecls(util);
    _ = abi;
    _ = core.ipmi;
    _ = core.oem;
    _ = intf.ipmi_intf;
    _ = util.bswap;
    _ = util.helper;
    _ = util.log;
    _ = util.strings;
    _ = util.strings.tables;
    _ = util.time;
}
