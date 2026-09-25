//! Namespace for the Zig side of the migration.
//!
//! Importing this file pulls in every header port and therefore every
//! `comptime` ABI assertion, which is what `zig build test` compiles.  It
//! imports command ports only for tests; their C symbols are exported when
//! selected through `exports.zig`.
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
    pub const registry = @import("intf/registry.zig");
    pub const dummy = @import("intf/dummy.zig");
    pub const open = @import("intf/open.zig");
    pub const lan = @import("intf/lan.zig");
    pub const lanplus = @import("intf/lanplus.zig");
    pub const lanplus_strings = @import("intf/lanplus_strings.zig");
    pub const lanplus_dump = @import("intf/lanplus_dump.zig");
    pub const serial_basic = @import("intf/serial_basic.zig");
    pub const serial_terminal = @import("intf/serial_terminal.zig");
    // Like the C transport, USB depends on Linux's SCSI generic driver.
    pub const usb = if (@import("builtin").target.os.tag == .linux and
        @hasDecl(@import("ipmi_c"), "sg_io_hdr_t"))
        @import("intf/usb.zig")
    else
        struct {};
};

/// Ports of the crypto primitives that used to come from OpenSSL.
///
/// Only the modules that stand alone appear here: the ones that `@export` C
/// symbols and call back into `log.c` are reached through `exports.zig`.  What
/// is left is the part worth testing directly, which is the arithmetic.
pub const crypto = struct {
    pub const aes_cbc = @import("crypto/aes_cbc.zig");
    pub const mac = @import("crypto/mac.zig");
    pub const md5 = @import("crypto/md5.zig");
    pub const payload = @import("crypto/payload.zig");
    pub const rakp = @import("crypto/rakp.zig");
    pub const v15_auth = @import("crypto/v15_auth.zig");
    pub const vectors = @import("crypto/vectors_test.zig");
};

/// Ports of the shared utilities.
pub const util = struct {
    pub const bswap = @import("util/bswap.zig");
    pub const fd_set = @import("util/fd_set.zig");
    pub const helper = @import("util/helper.zig");
    pub const log = @import("util/log.zig");
    pub const strings = @import("util/strings.zig");
    pub const time = @import("util/time.zig");
};

test {
    _ = @import("cmd/channel.zig");
    _ = @import("cmd/lanp.zig");
    _ = @import("cmd/sol.zig");
    _ = @import("cmd/vita.zig");
    _ = @import("cmd/lanp6.zig");
    _ = @import("cmd/dcmi.zig");
    _ = @import("cmd/dimm_spd.zig");
    _ = @import("cmd/hpmfwupg.zig");
    _ = @import("cmd/ime.zig");
    _ = @import("cmd/gendev.zig");
    _ = @import("frontend/ipmishell.zig");
    _ = @import("cmd/pef.zig");
    _ = @import("cmd/delloem.zig");
    _ = @import("cmd/sunoem.zig");
    _ = @import("frontend/shell_commands.zig");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(core);
    std.testing.refAllDecls(crypto);
    std.testing.refAllDecls(intf);
    std.testing.refAllDecls(util);
    _ = abi;
    _ = core.ipmi;
    _ = core.oem;
    _ = crypto.aes_cbc;
    _ = crypto.mac;
    _ = crypto.md5;
    _ = crypto.payload;
    _ = crypto.rakp;
    _ = crypto.v15_auth;
    _ = crypto.vectors;
    _ = intf.ipmi_intf;
    _ = intf.registry;
    _ = intf.dummy;
    _ = intf.open;
    _ = intf.lan;
    _ = intf.lanplus;
    _ = intf.lanplus_strings;
    _ = intf.lanplus_dump;
    _ = intf.serial_basic;
    _ = intf.serial_terminal;
    _ = intf.usb;
    _ = @import("cmd/isol.zig");
    _ = util.bswap;
    _ = util.helper;
    _ = util.log;
    _ = util.strings;
    _ = util.strings.tables;
    _ = util.time;
}
