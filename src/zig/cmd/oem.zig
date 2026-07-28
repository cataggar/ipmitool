//! Port of `lib/ipmi_oem.c`: the `-o <oemtype>` table and its three entry
//! points.
//!
//! Selected with `zig build -Dzig-modules=oem`, which drops `lib/ipmi_oem.c`
//! from the compile and links this module instead.  The exported symbols keep
//! the C names and signatures, so `lib/ipmi_main.c`, `src/plugins/lan/lan.c`
//! and `src/plugins/lanplus/*.c` link against it unchanged and unaware.
//!
//! Everything this module still needs from C — `lprintf`, `ipmi_sel_oem_init`,
//! `ipmi_intf_session_set_authtype` — is reached through the `ipmi_c` bridge.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const Intf = @import("../intf/intf.zig").Intf;
const OemHandle = @import("../core/oem.zig").OemHandle;

/// `IPMI_SESSION_AUTHTYPE_OEM`.
const authtype_oem: u8 = @intCast(c.IPMI_SESSION_AUTHTYPE_OEM);

/// `ipmi_oem_list`, including the `{ 0 }` terminator the C loops rely on.
///
/// Mutable because `struct ipmi_intf.oem` is a non-const pointer into this
/// table, exactly as in C.
var oem_list = [_]OemHandle{
    .{
        .name = "supermicro",
        .desc = "Supermicro IPMIv1.5 BMC with OEM LAN authentication support",
        .setup = &setupSupermicro,
    },
    .{
        .name = "intelwv2",
        .desc = "Intel SE7501WV2 IPMIv1.5 BMC with extra LAN communication support",
        .setup = null,
    },
    .{
        .name = "intelplus",
        .desc = "Intel IPMI 2.0 BMC with RMCP+ communication support",
        .setup = null,
    },
    .{
        .name = "icts",
        .desc = "IPMI 2.0 ICTS compliance support",
        .setup = null,
    },
    .{
        .name = "ibm",
        .desc = "IBM OEM support",
        .setup = &setupIbm,
    },
    .{
        .name = "i82571spt",
        .desc = "Intel 82571 MAC with integrated RMCP+ support in super pass-through mode",
        .setup = null,
    },
    .{
        .name = "kontron",
        .desc = "Kontron OEM big buffer support",
        .setup = null,
    },
    .{
        .name = "quanta",
        .desc = "Quanta IPMIv1.5 BMC with OEM LAN authentication support",
        .setup = &setupQuanta,
    },
    .{ .name = null, .desc = null, .setup = null },
};

/// Supermicro IPMIv2 BMCs use OEM authtype.
fn setupSupermicro(intf: *Intf) callconv(.c) c_int {
    c.ipmi_intf_session_set_authtype(@ptrCast(intf), authtype_oem);
    return 0;
}

fn setupIbm(_: *Intf) callconv(.c) c_int {
    const filename = std.c.getenv("IPMI_OEM_IBM_DATAFILE") orelse {
        c.lprintf(log.Level.err, "Unable to read IPMI_OEM_IBM_DATAFILE from environment");
        return -1;
    };
    return c.ipmi_sel_oem_init(filename);
}

/// Quanta IPMIv2 BMCs use OEM authtype.
fn setupQuanta(intf: *Intf) callconv(.c) c_int {
    c.ipmi_intf_session_set_authtype(@ptrCast(intf), authtype_oem);
    return 0;
}

/// `ipmi_oem_print` - print the list of OEM handles.
fn print() callconv(.c) void {
    c.lprintf(log.Level.notice, "\nOEM Support:");
    for (&oem_list) |*handle| {
        const name = handle.name orelse break;
        const desc = handle.desc orelse break;
        c.lprintf(log.Level.notice, "\t%-12s %s", name, desc);
    }
    c.lprintf(log.Level.notice, "");
}

/// `ipmi_oem_setup` - do the initial setup of an OEM handle.
///
/// Returns 0 on success and -1 on error.
fn setup(intf: *Intf, oemtype: ?[*:0]u8) callconv(.c) c_int {
    const requested = std.mem.span(oemtype orelse {
        print();
        return -1;
    });
    if (std.mem.eql(u8, requested, "help") or std.mem.eql(u8, requested, "list")) {
        print();
        return -1;
    }

    for (&oem_list) |*handle| {
        const name = handle.name orelse break;
        if (!std.mem.eql(u8, std.mem.span(name), requested)) continue;

        // Save the pointer for later use.
        intf.oem = handle;

        // Run the optional setup function if it is defined.
        const handle_setup = handle.setup orelse return 0;
        c.lprintf(
            log.Level.debug,
            "Running OEM setup for \"%s\"",
            handle.desc orelse @as([*:0]const u8, ""),
        );
        return handle_setup(intf);
    }

    return -1;
}

/// `ipmi_oem_active` - report whether `oemtype` is the active OEM handle.
///
/// Returns 1 when it is and 0 otherwise.
fn active(intf: ?*Intf, oemtype: ?[*:0]const u8) callconv(.c) c_int {
    const handle = (intf orelse return 0).oem orelse return 0;
    const name = handle.name orelse return 0;
    const wanted = oemtype orelse return 0;
    return @intFromBool(std.mem.eql(u8, std.mem.span(name), std.mem.span(wanted)));
}

// ---------------------------------------------------------------------------
// C ABI surface
//
// These three symbols are what `lib/ipmi_oem.c` used to provide.  The
// signature assertions below fail the build if a header changes the prototype
// without this module following.
// ---------------------------------------------------------------------------

comptime {
    abi.assertCallSignature(@TypeOf(print), @TypeOf(c.ipmi_oem_print));
    abi.assertCallSignature(@TypeOf(setup), @TypeOf(c.ipmi_oem_setup));
    abi.assertCallSignature(@TypeOf(active), @TypeOf(c.ipmi_oem_active));

    @export(&print, .{ .name = "ipmi_oem_print", .linkage = .strong });
    @export(&setup, .{ .name = "ipmi_oem_setup", .linkage = .strong });
    @export(&active, .{ .name = "ipmi_oem_active", .linkage = .strong });
}
