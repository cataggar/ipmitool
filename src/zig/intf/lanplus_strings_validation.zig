const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const tables = @import("lanplus_strings.zig");
const ValStr = @import("../util/table_types.zig").ValStr;

comptime {
    abi.assertLayout(ValStr, c.struct_valstr);

    const rakp_codes = .{
        c.IPMI_RAKP_STATUS_NO_ERRORS,
        c.IPMI_RAKP_STATUS_INSUFFICIENT_RESOURCES_FOR_SESSION,
        c.IPMI_RAKP_STATUS_INVALID_SESSION_ID,
        c.IPMI_RAKP_STATUS_INVALID_PAYLOAD_TYPE,
        c.IPMI_RAKP_STATUS_INVALID_AUTHENTICATION_ALGORITHM,
        c.IPMI_RAKP_STATUS_INVALID_INTEGRITTY_ALGORITHM,
        c.IPMI_RAKP_STATUS_NO_MATCHING_AUTHENTICATION_PAYLOAD,
        c.IPMI_RAKP_STATUS_NO_MATCHING_INTEGRITY_PAYLOAD,
        c.IPMI_RAKP_STATUS_INACTIVE_SESSION_ID,
        c.IPMI_RAKP_STATUS_INVALID_ROLE,
        c.IPMI_RAKP_STATUS_UNAUTHORIZED_ROLE_REQUESTED,
        c.IPMI_RAKP_STATUS_INSUFFICIENT_RESOURCES_FOR_ROLE,
        c.IPMI_RAKP_STATUS_INVALID_NAME_LENGTH,
        c.IPMI_RAKP_STATUS_UNAUTHORIZED_NAME,
        c.IPMI_RAKP_STATUS_UNAUTHORIZED_GUID,
        c.IPMI_RAKP_STATUS_INVALID_INTEGRITY_CHECK_VALUE,
        c.IPMI_RAKP_STATUS_INVALID_CONFIDENTIALITY_ALGORITHM,
        c.IPMI_RAKP_STATUS_NO_CIPHER_SUITE_MATCH,
        c.IPMI_RAKP_STATUS_ILLEGAL_PARAMETER,
    };
    for (rakp_codes, 0..) |value, index| {
        if (tables.rakp_return_codes[index].val != value)
            @compileError("RAKP status table drifted from C headers");
    }

    const priv_codes = .{ c.IPMI_PRIV_CALLBACK, c.IPMI_PRIV_USER, c.IPMI_PRIV_OPERATOR, c.IPMI_PRIV_ADMIN, c.IPMI_PRIV_OEM };
    for (priv_codes, 0..) |value, index| {
        if (tables.priv_levels[index].val != value)
            @compileError("privilege table drifted from C headers");
    }
}
