//! Lookup tables from `src/plugins/lanplus/lanplus_strings.c`.

const c = @import("ipmi_c");
const ValStr = @import("../util/helper.zig").ValStr;

pub const rakp_return_codes = [_]ValStr{
    .{ .val = c.IPMI_RAKP_STATUS_NO_ERRORS, .str = "no errors" },
    .{ .val = c.IPMI_RAKP_STATUS_INSUFFICIENT_RESOURCES_FOR_SESSION, .str = "insufficient resources for session" },
    .{ .val = c.IPMI_RAKP_STATUS_INVALID_SESSION_ID, .str = "invalid session ID" },
    .{ .val = c.IPMI_RAKP_STATUS_INVALID_PAYLOAD_TYPE, .str = "invalid payload type" },
    .{ .val = c.IPMI_RAKP_STATUS_INVALID_AUTHENTICATION_ALGORITHM, .str = "invalid authentication algorithm" },
    .{ .val = c.IPMI_RAKP_STATUS_INVALID_INTEGRITTY_ALGORITHM, .str = "invalid integrity algorithm" },
    .{ .val = c.IPMI_RAKP_STATUS_NO_MATCHING_AUTHENTICATION_PAYLOAD, .str = "no matching authentication algorithm" },
    .{ .val = c.IPMI_RAKP_STATUS_NO_MATCHING_INTEGRITY_PAYLOAD, .str = "no matching integrity payload" },
    .{ .val = c.IPMI_RAKP_STATUS_INACTIVE_SESSION_ID, .str = "inactive session ID" },
    .{ .val = c.IPMI_RAKP_STATUS_INVALID_ROLE, .str = "invalid role" },
    .{ .val = c.IPMI_RAKP_STATUS_UNAUTHORIZED_ROLE_REQUESTED, .str = "unauthorized role requested" },
    .{ .val = c.IPMI_RAKP_STATUS_INSUFFICIENT_RESOURCES_FOR_ROLE, .str = "insufficient resources for role" },
    .{ .val = c.IPMI_RAKP_STATUS_INVALID_NAME_LENGTH, .str = "invalid name length" },
    .{ .val = c.IPMI_RAKP_STATUS_UNAUTHORIZED_NAME, .str = "unauthorized name" },
    .{ .val = c.IPMI_RAKP_STATUS_UNAUTHORIZED_GUID, .str = "unauthorized GUID" },
    .{ .val = c.IPMI_RAKP_STATUS_INVALID_INTEGRITY_CHECK_VALUE, .str = "invalid integrity check value" },
    .{ .val = c.IPMI_RAKP_STATUS_INVALID_CONFIDENTIALITY_ALGORITHM, .str = "invalid confidentiality algorithm" },
    .{ .val = c.IPMI_RAKP_STATUS_NO_CIPHER_SUITE_MATCH, .str = "no matching cipher suite" },
    .{ .val = c.IPMI_RAKP_STATUS_ILLEGAL_PARAMETER, .str = "illegal parameter" },
    .{ .val = 0, .str = null },
};

pub const priv_levels = [_]ValStr{
    .{ .val = c.IPMI_PRIV_CALLBACK, .str = "callback" },
    .{ .val = c.IPMI_PRIV_USER, .str = "user" },
    .{ .val = c.IPMI_PRIV_OPERATOR, .str = "operator" },
    .{ .val = c.IPMI_PRIV_ADMIN, .str = "admin" },
    .{ .val = c.IPMI_PRIV_OEM, .str = "oem" },
    .{ .val = 0, .str = null },
};

pub fn exportSymbols() void {
    @export(&rakp_return_codes, .{ .name = "ipmi_rakp_return_codes", .linkage = .strong });
    @export(&priv_levels, .{ .name = "ipmi_priv_levels", .linkage = .strong });
}
