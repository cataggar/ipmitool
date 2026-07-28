//! Port of `include/ipmitool/ipmi_oem.h`.
//!
//! Only the type lives here.  The implementation of `lib/ipmi_oem.c` — the OEM
//! table and the three exported entry points — is `src/zig/cmd/oem.zig`, which
//! keeps the header/translation-unit split of the C tree: header ports go to
//! `core/`, `intf/` or `util/`, translation-unit ports go to `cmd/` or `intf/`.

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const intf_mod = @import("../intf/intf.zig");

/// `struct ipmi_oem_handle`: one entry of the `-o <oemtype>` table.
pub const OemHandle = extern struct {
    name: ?[*:0]const u8,
    desc: ?[*:0]const u8,
    setup: ?*const fn (intf: *intf_mod.Intf) callconv(.c) c_int,
};

comptime {
    abi.assertLayout(OemHandle, c.struct_ipmi_oem_handle);
}
