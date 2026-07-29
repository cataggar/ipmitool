//! The exact text glibc's `assert()` prints for the branches this migration
//! reproduces.
//!
//! These live apart from the modules that use them for two reasons.  Several
//! are shared by more than one call site and have to stay identical, and
//! `vectors_test.zig` pins every one of them against what the C actually
//! printed (`tests/crypto/vectors/aborts.txt`) — which it can only do from a
//! module that pulls in no C symbols of its own.
//!
//! Only the expression is reproduced, not the file, line and function glibc
//! prints alongside it: those are toolchain dependent and gcc and clang
//! disagree on both.  See `doc/zig-migration/crypto.md`.

const c = @import("ipmi_c");

/// Whether the C was configured with SHA-256 support, which changes the text
/// of the RAKP algorithm assertion because the third disjunct is `#ifdef`ed.
pub const have_sha256 = @hasDecl(c, "HAVE_CRYPTO_SHA256");

/// `lanplus_rakp2_hmac_matches`, `lanplus_rakp4_hmac_matches`,
/// `lanplus_generate_sik` and `lanplus_generate_rakp3_authcode` all make this
/// assertion.
pub const supported_auth_algs = if (have_sha256)
    "(session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_SHA1) " ++
        "|| (session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_MD5) " ++
        "|| (session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_SHA256)"
else
    "(session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_SHA1) " ++
        "|| (session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_MD5)";

/// The `intelplus` branch of `lanplus_rakp4_hmac_matches` asserts on the
/// *integrity* algorithm even though it is picking an *authentication* one, so
/// `-o intelplus` with cipher suite 17 aborts.  Reproduced deliberately; see
/// the note in `doc/zig-migration/crypto.md`.
pub const intelplus_integrity =
    "(session->v2_data.integrity_alg == IPMI_INTEGRITY_HMAC_SHA1_96) " ++
    "|| (session->v2_data.integrity_alg == IPMI_INTEGRITY_HMAC_MD5_128)";

/// Both `lanplus_encrypt_aes_cbc_128` and `lanplus_decrypt_aes_cbc_128`.
pub const aes_block_multiple = "(input_length % IPMI_CRYPT_AES_CBC_128_BLOCK_SIZE) == 0";

/// `lanplus_encrypt_payload` and `lanplus_decrypt_payload`, reached once the
/// `IPMI_CRYPT_NONE` case has been handled.
pub const crypt_alg_is_aes = "crypt_alg == IPMI_CRYPT_AES_CBC_128";
