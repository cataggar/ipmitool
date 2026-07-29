# Crypto port (Phase 3)

Issue [#9](https://github.com/cataggar/ipmitool/issues/9) — replace the OpenSSL
`libcrypto` dependency with Zig's `std.crypto`.

This is the highest-risk port in the rewrite: a subtle divergence produces a
session that only fails against real hardware, which we cannot test. So the
whole port is driven by **test vectors captured from the OpenSSL-backed C build
before a single line of Zig was written**, and every Zig implementation is
asserted to reproduce them bit for bit.

## What was ported

| C translation unit | Zig module | Exported symbols |
| --- | --- | --- |
| `src/plugins/lan/md5.c` | `src/zig/crypto/md5.zig` | `md5_init`, `md5_append`, `md5_finish` |
| `src/plugins/lan/auth.c` | `src/zig/crypto/auth.zig` | `ipmi_auth_md5`, `ipmi_auth_md2`, `ipmi_auth_special` |
| `src/plugins/lanplus/lanplus_crypt_impl.c` | `src/zig/crypto/lanplus_crypt_impl.zig` | `lanplus_seed_prng`, `lanplus_rand`, `lanplus_HMAC`, `lanplus_encrypt_aes_cbc_128`, `lanplus_decrypt_aes_cbc_128` |
| `src/plugins/lanplus/lanplus_crypt.c` | `src/zig/crypto/lanplus_crypt.zig` | `lanplus_rakp2_hmac_matches`, `lanplus_rakp4_hmac_matches`, `lanplus_generate_rakp3_authcode`, `lanplus_generate_sik`, `lanplus_generate_k1`, `lanplus_generate_k2`, `lanplus_encrypt_payload`, `lanplus_decrypt_payload`, `lanplus_has_valid_auth_code` |

`build.zig` module names: `md5`, `auth`, `lanplus-crypt-impl`, `lanplus-crypt`.

Supporting pure-Zig modules with no C ABI surface, so the maths can be unit
tested independently of the exported wrappers:

| Module | Contents |
| --- | --- |
| `src/zig/crypto/aes_cbc.zig` | AES-128-CBC, `encrypt` / `decrypt`, safe for in-place use |
| `src/zig/crypto/mac.zig` | algorithm selection, digest and authcode lengths, HMAC dispatch |
| `src/zig/crypto/rakp.zig` | RAKP 2/3/4 and SIK message assembly |
| `src/zig/crypto/payload.zig` | confidentiality padding arithmetic |
| `src/zig/crypto/v15_auth.zig` | IPMI v1.5 authcode assembly |
| `src/zig/util/cassert.zig` | `assert()` parity: diagnostic on stderr then `SIGABRT` |

## Algorithm mapping

| C (OpenSSL) | Zig |
| --- | --- |
| `EVP_aes_128_cbc` + `EVP_CipherUpdate` | `std.crypto.core.aes.Aes128` driven by a hand-rolled CBC mode in `aes_cbc.zig` |
| `EVP_sha1` | `std.crypto.hash.Sha1` |
| `EVP_sha256` | `std.crypto.hash.sha2.Sha256` |
| `EVP_md5` | `std.crypto.hash.Md5` |
| `HMAC(EVP_*, ...)` | `std.crypto.auth.hmac.Hmac(...)` |
| `RAND_load_file("/dev/urandom", n)` / `RAND_bytes` | `std.Random.ChaCha` pool seeded from `/dev/urandom` |
| bundled `md5.c` (RSA reference implementation) | `std.crypto.hash.Md5` behind the original `md5_state_t` layout |

`std` has no CBC helper, so `aes_cbc.zig` implements it directly: XOR the
plaintext block with the previous ciphertext block (the IV for the first),
encrypt, and carry the ciphertext forward. Decryption carries the *input* block
forward before it is overwritten, so `input == output` (which
`lanplus_encrypt_payload` relies on) is safe.

Both `lanplus_encrypt_aes_cbc_128` and `lanplus_decrypt_aes_cbc_128` keep the C
contract of asserting that the length is a non-zero multiple of 16 — see
"assertion parity" below.

## MD2

**MD2 is not implemented, deliberately.**

OpenSSL 3.x dropped MD2 entirely, so `HAVE_CRYPTO_MD2` is already impossible to
satisfy on any platform this project builds on. `build.zig` hardwires it to
undefined and the archived baseline oracle was built the same way, which means
`-A MD2` has **never** been exercisable in this project's supported
configurations. Implementing MD2 in Zig would therefore *add* behavior rather
than preserve it.

What the C does when `HAVE_CRYPTO_MD2` is undefined, and what `auth.zig`
reproduces exactly:

```
ipmi_auth_md2() → writes 16 zero bytes into the authcode buffer,
                  prints (via printf, not lprintf, so on stdout):
                  "WARNING: No internal support for MD2!  Please re-compile with OpenSSL."
                  and returns the authcode buffer.
```

This is a clean, non-fatal error, not a crash — the request goes out with a
zeroed authcode and the BMC rejects it. The `auth/md2/unsupported` vector pins
the 16 zero bytes.

`auth.zig` additionally contains a `comptime` guard: if someone ever restores a
`HAVE_CRYPTO_MD2` build, the Zig module fails to compile with an explicit
message rather than silently diverging.

`lib/ipmi_lanp.c` only ever prints the *strings* "MD2"/"MD5" for
`channel authcap` output; it never links libcrypto and needed no change.

## Truncation lengths

IPMI truncates keyed hashes, and the lengths differ per algorithm. These are
taken from the constants in `src/plugins/lanplus/lanplus.h`, not from memory:

| Constant | Value | Full digest | Used for |
| --- | --- | --- | --- |
| `IPMI_SHA1_AUTHCODE_SIZE` | 12 | 20 | HMAC-SHA1-96 integrity, RAKP 2/3/4 with SHA-1 |
| `IPMI_HMAC_MD5_AUTHCODE_SIZE` | 16 | 16 | HMAC-MD5-128 integrity, RAKP with MD5 (no truncation) |
| `IPMI_HMAC_SHA256_AUTHCODE_SIZE` | 16 | 32 | HMAC-SHA256-128 integrity, RAKP with SHA-256 |

Two separate number spaces use overlapping values and the C treats them
differently:

* `lanplus_HMAC()` maps `0x01`→SHA-1, `0x02`→MD5, and **both** `0x03` and `0x04`
  →SHA-256, because it is called with authentication algorithm ids *and*
  integrity algorithm ids. `mac.zig`'s `algorithmFor` reproduces this exactly.
* `lanplus_has_valid_auth_code()` (integrity space) and
  `lanplus_rakp4_hmac_matches()` (authentication space) each have their own
  `switch` that `assert(0)`s on the value the *other* space owns —
  `0x03` (`IPMI_INTEGRITY_MD5_128`) and `0x04` respectively. `lanplus_crypt.zig`
  therefore keeps those as separate explicit switches instead of routing them
  through `mac.zig`, so the abort behavior survives.

## Confidentiality padding

`lanplus_encrypt_payload` pads to the AES block size *including* a trailing
pad-length byte:

```
mod        = (payload_len + 1) % 16
pad_length = mod == 0 ? 0 : 16 - mod
```

The pad bytes are the ascending sequence `1, 2, 3, ...` (not zeros, not
PKCS#7), followed by the single pad-length byte. Every boundary is covered by
the `payload/aes/*` vectors: lengths 0, 1, 2, 13, 14, 15, 16, 17, 30, 31, 32,
33, 47, 100 and 255.

`lanplus_decrypt_payload` reads the last byte as the pad length. Where the C
would index out of bounds on a malformed payload, `payload.zig` returns `null`
and the caller prints `"Malformed payload padding"` and aborts, matching the
`assert()` the C would hit.

With `IPMI_CRYPT_NONE` the C is asymmetric and this is preserved:
`lanplus_encrypt_payload` sets `*bytes_written = input_length` and copies
**nothing**, while `lanplus_decrypt_payload` does a `memmove`. The
`payload/none/40` vector pins this (the output buffer keeps its `0xcc` fill).

## Endianness

Two C quirks are reproduced verbatim rather than corrected:

* `rakp.zig` — session ids are always written little-endian, but the 16-byte
  random-number and GUID fields are **byte-reversed on big-endian hosts**. That
  reversal is a property of the C code, not of the IPMI spec.
* `v15_auth.zig` — the v1.5 authcode hashes `session_id` in **host** byte order
  (no swap at all) while `in_seq` is always little-endian. This is arguably a C
  bug, but it is the behavior on the wire today.

Both have dedicated unit tests that pin the byte order for each host
endianness. The captured vectors were generated on a little-endian host, so
only the little-endian path is vector-backed; the big-endian path is covered by
inspection plus those unit tests.

## PRNG

The C seeds OpenSSL's global RNG with `RAND_load_file("/dev/urandom", bytes)`
and draws from `RAND_bytes`. There is no `std.crypto.random` in this Zig, so
`lanplus_crypt_impl.zig` keeps a module-level `std.Random.ChaCha` pool seeded
once from `/dev/urandom` (via `std.c.open`/`read`/`close`) and draws from that.

Two intentional differences, both invisible to callers:

* `lanplus_seed_prng(bytes)` ignores its `bytes` argument — the ChaCha pool has
  a fixed seed size. It keeps the `0` success / `1` failure return contract, so
  the caller's error path is unchanged.
* `lanplus_rand()` seeds the pool lazily if `lanplus_seed_prng` was never
  called, which the OpenSSL version also effectively did.

This avoids three syscalls per SOL packet, which the C incurred.

## Assertion parity

`lanplus_crypt.c` and `lanplus_crypt_impl.c` use `assert()` heavily and some of
those asserts are reachable from malformed BMC responses, so they are part of
observable behavior. `src/zig/util/cassert.zig` prints a glibc-shaped
diagnostic and raises `SIGABRT` through `std.c.abort()`, and each call site
carries the original file name and line number.

One documented divergence: glibc prefixes the message with the program name
taken from `program_invocation_name`. `std.os.argv` does not exist in this Zig
version, so the prefix is omitted. The message body, the file/line, the
function name, the stream (stderr) and the exit signal all match.

## Where the vectors came from

`tests/crypto/gen_vectors.c` is a C harness that links the **original,
OpenSSL-backed** C translation units and dumps every input/output pair as a
text fixture. It is wired into `build.zig` as:

```sh
zig build gen-crypto-vectors
```

The step compiles the pristine `md5.c`, `auth.c`, `lanplus_crypt_impl.c` and
`lanplus_crypt.c` against `libcrypto` and rewrites `tests/crypto/vectors/*.txt`
in place. It is not part of `zig build test` — the fixtures are checked in and
treated as frozen evidence. Re-running it is only meaningful on a checkout that
still has the C implementations.

For the functions that only report through `verbose` output, the harness
installs a capturing `printbuf` so the C's own intermediate values (the
generated IV, the K1/K2 material, the RAKP message buffers) end up in the
fixtures too, rather than being re-derived by the Zig side.

> **Azure Linux note:** `/etc/ssl/openssl.cnf` there activates the SymCrypt
> provider, which refuses HMAC-MD5 and makes the generator fail. The build step
> runs with `OPENSSL_CONF=/dev/null` to select OpenSSL's built-in default
> provider. This affects vector *generation* only.

### Coverage

**401 cases**, parsed and asserted by `src/zig/crypto/vectors_test.zig`:

| Fixture | Cases | What it pins |
| --- | --- | --- |
| `md5.txt` | 28 | the RFC 1321 suite, message lengths straddling every block and length-encoding boundary (55/56/57, 63/64/65, 119/120/121, 128, 191, 1000), `md5_append` called in 1/2/4/8/16/32/64-byte chunks, and a zero-length `md5_append` |
| `auth.txt` | 8 | `ipmi_auth_md5` and `ipmi_auth_special` over several password/session-id/sequence combinations, plus the MD2 stub |
| `hmac.txt` | 320 | all four algorithm ids × key lengths 0, 1, 16, 20, 32, 63, 64, 65, 100, 128 × data lengths 0, 1, 16, 20, 55, 64, 65, 200 — the 63/64/65 and 100/128 keys straddle the block-size boundary where HMAC hashes the key instead of padding it |
| `aes_cbc.txt` | 17 | encrypt and decrypt at 0, 1, 2, 3, 4, 5, 10 and 32 blocks, plus one encrypt with `input == output` |
| `payload.txt` | 16 | every padding residue class plus the `IPMI_CRYPT_NONE` asymmetry |
| `rakp.txt` | 12 | complete RAKP 1–4 sequences for SHA-1, MD5 and SHA-256, with and without a Kg, plus the no-username, long-username, `i82571spt`, `intelplus` and no-auth paths. Each case pins the exact RAKP 2/3/4 and SIK message buffers, every authcode and return code, the SIK, K1, K2, the integrity authcode length, and both the accepting and the tampered `lanplus_has_valid_auth_code` results |

The vectors_test module asserts the exact per-file case counts, so a truncated
or partially regenerated fixture fails the build rather than silently reducing
coverage.

## Dropping `-lcrypto`

`build.zig` no longer ties `-lcrypto` to `-Dopenssl`. It now follows the source
inventory:

```zig
const libcrypto_c_sources = .{
    "src/plugins/lanplus/lanplus_crypt_impl.c",
    "src/plugins/lan/auth.c",
};
```

`withLibcrypto()` appends `crypto` to the link line only if one of those files
is still being compiled as C — that is, only if the corresponding `zig_modules`
entry is *not* selected. `auth.c` is additionally skipped under
`-Dinternal-md5`, since that sends it to the bundled MD5 instead of OpenSSL's.

Consequences:

* Default build (all C): `libcrypto.so.3` still linked, as before.
* `-Dzig-modules=md5,auth,lanplus-crypt-impl,lanplus-crypt`: **no libcrypto at
  all**, and no undefined OpenSSL symbols in the binary.
* The golden suite's `ipmitool-zig` binary selects every module, so it gets its
  own link-line computation and is also libcrypto-free.

Two related cleanups:

* `src/plugins/lanplus/lanplus.c` had `#include <openssl/rand.h>` but used no
  OpenSSL symbol — removed.
* The `-Dintf-lanplus requires libcrypto` gate now also accepts "…or the Zig
  crypto port is selected", so `-Dopenssl=false -Dzig-modules=…` builds a
  working lanplus rather than silently disabling it.

`HAVE_CRYPTO_SHA256` stays defined regardless: it gates cipher-suite tables in
`lib/ipmi_strings.c`, `include/ipmitool/ipmi_intf.h`, `lanplus.c` and
`lanplus_dump.c`, so turning it off would change `ipmitool -h`-adjacent output.
It describes an available *algorithm*, which is now supplied by `std.crypto`.

## `md5_state_t` layout

`md5.c` is not only used by `auth.c`; `lib/ipmi_hpmfwupg.c` uses it
unconditionally and embeds `md5_state_t` by value. The struct layout is
therefore part of the ABI and is preserved exactly:

```c
typedef struct md5_state_s {
    md5_word_t count[2];  /* message length in bits, lsw first */
    md5_word_t abcd[4];   /* digest buffer */
    md5_byte_t buf[64];   /* accumulate block */
} md5_state_t;            /* 88 bytes */
```

`md5.zig` treats this as an on-the-wire representation of
`std.crypto.hash.Md5` and converts in both directions on every call:
`abcd[i] ↔ s[i]`, `count` is the 64-bit bit counter (`total_len * 8`) stored
lsw-first, and `buf_len = (count[0] >> 3) & 63`. `restore` builds the `Md5` with
a struct literal rather than field assignment, so a rename in `std` becomes a
compile error instead of a silent miscompile. `abi.assertLayout` pins the size
and every offset.
