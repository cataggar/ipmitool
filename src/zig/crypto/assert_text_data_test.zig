const std = @import("std");
const options = @import("build_options");
const text = @import("assert_text.zig");

test "RAKP assertion text follows the SHA256 build option without C headers" {
    const prefix = "(session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_SHA1) " ++
        "|| (session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_MD5)";
    const suffix = " || (session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_SHA256)";
    try std.testing.expectEqual(options.have_crypto_sha256, text.have_sha256);
    try std.testing.expectEqualStrings(
        if (options.have_crypto_sha256) prefix ++ suffix else prefix,
        text.supported_auth_algs,
    );
}
