# Crypto port (Phase 3)

Issue [#9](https://github.com/cataggar/ipmitool/issues/9) — replace the OpenSSL
`libcrypto` dependency with Zig's `std.crypto`.

This is the highest-risk port in the rewrite: a subtle divergence produces a
session that only fails against real hardware, which we cannot test. So the
whole port is driven by **test vectors captured from the OpenSSL-backed C build
before a single line of Zig was written**, and every Zig implementation is
asserted to reproduce them bit for bit.

The 173-case golden harness under `tests/golden/` does **not** exercise any of
this code — it drives the `dummy` interface, which has no session layer, so
nothing below the command layer is reachable from it (see
[#26](https://github.com/cataggar/ipmitool/issues/26)). The 681 captured
vectors are therefore not a supplement to the golden run; for this port they
are the verification.

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
| `src/zig/crypto/assert_text.zig` | the exact `assert()` expression strings, shared by the call sites and pinned by the vectors |
| `src/zig/util/cassert.zig` | `assert()` parity: diagnostic on stderr then `SIGABRT` |

## How each exported function is verified

| Exported function | Fixture | Cases |
| --- | --- | --- |
| `md5_init` / `md5_append` / `md5_finish` | `md5.txt` | 28 |
| `ipmi_auth_md5` | `auth.txt` | 72 |
| `ipmi_auth_special` | `auth.txt` | 21 |
| `ipmi_auth_md2` | `auth.txt` | 1 (the unsupported stub; see *MD2*) |
| `lanplus_HMAC` | `hmac.txt`, `aborts.txt` | 320 + 1 |
| `lanplus_encrypt_aes_cbc_128` | `aes_cbc.txt`, `aborts.txt` | 37 + 1 |
| `lanplus_decrypt_aes_cbc_128` | `aes_cbc.txt`, `aborts.txt` | 17 + 1 |
| `lanplus_encrypt_payload` | `payload.txt`, `aborts.txt` | 59 + 1 |
| `lanplus_decrypt_payload` | `payload.txt`, `aborts.txt` | 59 + 3 |
| `lanplus_rakp2_hmac_matches` | `rakp.txt`, `aborts.txt` | 29 + 1 |
| `lanplus_rakp4_hmac_matches` | `rakp.txt`, `aborts.txt` | 29 + 1 |
| `lanplus_generate_rakp3_authcode` | `rakp.txt`, `aborts.txt` | 29 + 1 |
| `lanplus_generate_sik` | `rakp.txt`, `aborts.txt` | 29 + 1 |
| `lanplus_generate_k1` | `rakp.txt` | 29 |
| `lanplus_generate_k2` | `rakp.txt` | 29 |
| `lanplus_has_valid_auth_code` | `integrity.txt`, `rakp.txt`, `aborts.txt` | 85 + 29 + 1 |
| `lanplus_seed_prng` | **none** | nondeterministic; see *What has no vector coverage* |
| `lanplus_rand` | **none** | nondeterministic; see *What has no vector coverage* |

The `payload.txt` and `rakp.txt` cases each pin several intermediate buffers,
so the case counts above understate the number of individual byte-string
comparisons.

Every one of these functions is driven **through its exported C-ABI entry
point** by the vector tests, not re-implemented alongside it; see *The tests
must call the shipped code, not re-implement it* below. The only exceptions are
`lanplus_seed_prng` and `lanplus_rand`.

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
  `0x03` (`IPMI_INTEGRITY_MD5_128`) and `0x04` respectively.
  `mac.zig` therefore holds **four** separate lookups, each returning null
  exactly where the C asserts. `abort/integrity/md5-128` in `aborts.txt` pins
  the resulting abort.

| `mac.zig` lookup | C site | Accepts | Asserts on |
| --- | --- | --- | --- |
| `algorithmFor` | `lanplus_HMAC` | 0x01, 0x02, 0x03, 0x04 | everything else |
| `integrityAuthcodeLength` | `lanplus_has_valid_auth_code` | 0x01→12, 0x02→16, 0x04→16 | 0x03 |
| `rakpAuthcodeLength` | `lanplus_rakp4_hmac_matches`, non-`intelplus` | 0x01→12, 0x02→16, 0x03→16 | 0x04 |
| `intelplusRakpAuthcodeLength` | `lanplus_rakp4_hmac_matches`, `intelplus` | 0x01→12, 0x02→16 | 0x04 |

All four live in `mac.zig` rather than being duplicated at their call sites,
because a length that exists in more than one place is a length that can drift.
They share `Algorithm.authcodeLength` for the numbers and differ only in which
algorithm ids they accept — which is exactly how the C's macros and switches
relate. The mutation battery below still mutates each table *individually* (by
replacing its delegation with a literal) so that a future edit reintroducing
per-table numbers stays covered.

## Confidentiality padding

`lanplus_encrypt_payload` pads to the AES block size *including* a trailing
pad-length byte:

```
mod        = (payload_len + 1) % 16
pad_length = mod == 0 ? 0 : 16 - mod
```

The pad bytes are the ascending sequence `1, 2, 3, ...` (not zeros, not
PKCS#7), followed by the single pad-length byte. Rather than sample the
boundaries, the `payload/aes/*` vectors cover **every** length from 0 to 48
plus 100, 127, 128, 255, 256 and 511, so all sixteen residue classes are
exercised repeatedly and an off-by-one in the pad length has nowhere to hide.

`lanplus_decrypt_payload` reads the last byte as the pad length. Where the C
would index out of bounds on a malformed payload, `payload.zig` returns `null`
and the caller prints `"Malformed payload padding"` and aborts, matching the
`assert()` the C would hit.

With `IPMI_CRYPT_NONE` the C is asymmetric and this is preserved:
`lanplus_encrypt_payload` sets `*bytes_written = input_length` and copies
**nothing**, while `lanplus_decrypt_payload` does a `memmove`. The
`payload/none/*` vectors pin this (the output buffer keeps its `0xcc` fill).

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

`tests/crypto/vectors/aborts.txt` captures all twelve reachable branches by
`fork()`ing the C harness, letting the child abort, and recording the wait
status and the message glibc printed. All twelve die on signal 6 (`SIGABRT`);
`vectors_test.zig` asserts that and compares each captured assertion expression
against the string the Zig call site carries.

Three divergences, all documented rather than fixed:

* glibc prefixes the message with the program name taken from
  `program_invocation_name`. `std.os.argv` does not exist in this Zig version,
  so the prefix is omitted.
* **gcc and clang disagree with each other** about the rest of the line. For a
  multi-line `assert(...)`, gcc reports the line the `assert` opens on and the
  bare function name (`lanplus_rakp2_hmac_matches`); clang — and therefore
  `zig cc`, and therefore the C build this project produces — reports the line
  the closing paren is on and the full prototype
  (`int lanplus_rakp2_hmac_matches(const struct ipmi_session *, ...)`). They
  also disagree on `__FILE__`: autotools compiles from inside the source
  directory and gets a bare basename, `zig build` passes an absolute path.
  There is therefore no single byte-exact target. The port follows the gcc
  convention with a repo-relative path.
* Because of the above, `aborts.txt` deliberately records only the signal and
  the assertion **expression**, which are identical under every toolchain.

### A real C bug, reproduced

`lanplus_rakp4_hmac_matches` has an `ipmi_oem_active(intf, "intelplus")` branch
that switches on `session->v2_data.integrity_alg` — the *integrity* algorithm —
even though it is choosing which hash to verify the RAKP 4 *authentication*
code with, and asserts the value is SHA1-96 or MD5-128. Cipher suite 17
negotiates HMAC-SHA256-128 integrity, so:

```sh
ipmitool -I lanplus -o intelplus -C 17 ...
```

aborts with `SIGABRT` in the C today. This is captured as
`abort/rakp4/intelplus-sha256` and reproduced by the port. It is **not** fixed
here: this PR is a like-for-like port, and changing it would be a behavior
change that belongs in its own change.

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

Re-running the generator reproduces every fixture byte for byte except
`payload.txt`, whose `lanplus_encrypt_payload` cases embed a fresh random IV
drawn inside the C. The abort-capture harness in `gen_vectors.c` is also
occasionally seen to record `SIGPIPE` instead of `SIGABRT` for one case when
the aborting child loses the race to write its diagnostic; the committed
fixture holds the correct `SIGABRT` capture.

> **Azure Linux note:** `/etc/ssl/openssl.cnf` there activates the SymCrypt
> provider, which refuses HMAC-MD5 and makes the generator fail. The build step
> runs with `OPENSSL_CONF=/dev/null` to select OpenSSL's built-in default
> provider. This affects vector *generation* only.

### Coverage

**681 cases**, parsed and asserted by `src/zig/crypto/vectors_test.zig`:

| Fixture | Cases | What it pins |
| --- | --- | --- |
| `md5.txt` | 28 | the RFC 1321 suite, message lengths straddling every block and length-encoding boundary (55/56/57, 63/64/65, 119/120/121, 128, 191, 1000), `md5_append` called in 1/2/4/8/16/32/64-byte chunks, and a zero-length `md5_append` |
| `auth.txt` | 94 | `ipmi_auth_md5` over six asymmetric `session_id`/`in_seq` pairs × twelve data lengths (0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127), `ipmi_auth_special` at every password length 0–20, and the MD2 stub |
| `hmac.txt` | 320 | all four algorithm ids × key lengths 0, 1, 16, 20, 32, 63, 64, 65, 100, 128 × data lengths 0, 1, 16, 20, 55, 64, 65, 200 — the 63/64/65 and 100/128 keys straddle the block-size boundary where HMAC hashes the key instead of padding it |
| `aes_cbc.txt` | 54 | encrypt and decrypt at 0–10, 16 and 32 blocks; twelve degenerate keys (all-zero, all-ones, each single bit set); eight IV variations; and eight `input == output` cases at 1–4 blocks in both directions |
| `payload.txt` | 59 | every payload length 0–48 exhaustively, plus 100, 127, 128, 255, 256 and 511, so every padding residue class is hit from both sides; plus four `IPMI_CRYPT_NONE` cases pinning the encrypt/decrypt asymmetry |
| `integrity.txt` | 85 | `lanplus_has_valid_auth_code` for all three integrity algorithms × three K1 lengths × nine packet lengths, plus its four early returns — see below |
| `rakp.txt` | 29 | complete RAKP 1–4 sequences across SHA-1, MD5 and SHA-256, with and without a Kg, plus the no-username, no-password, long-username, single-character-username, every-privilege-level, name-only-lookup, `i82571spt` (with and without Kg), `intelplus` and no-auth paths, and ten cases that decouple the authentication algorithm from the integrity algorithm — two of them specifically so the `intelplus` truncation table cannot hide behind the non-`intelplus` one on the diagonal. Each case pins the exact RAKP 2/3/4 and SIK message buffers, every authcode and return code, the SIK, K1, K2, the integrity authcode length, and both the accepting and the tampered `lanplus_has_valid_auth_code` results |
| `aborts.txt` | 12 | every reachable `assert()` branch — see below |

The vectors_test module asserts the exact per-file case counts, so a truncated
or partially regenerated fixture fails the build rather than silently reducing
coverage.

#### Why `integrity.txt` exists separately

Truncation is the parity trap most likely to survive every other test: an
implementation that compares the full 20-byte SHA-1 digest instead of the first
12 bytes still *accepts* every valid packet, and only differs when a BMC sends
something the C would have accepted and it does not (or vice versa).

So each `integrity/*` case records not just the answer but the untruncated
digest and its length, and then four further answers with a single bit flipped
in the packet body, in the last authcode byte, and in the first authcode byte —
and, crucially, one where the authcode is replaced by the **tail** of the
untruncated digest. Only an implementation that truncates at the right offset
rejects that last one. `vectors_test.zig` reproduces all five answers.

#### What has no vector coverage

* `lanplus_seed_prng` and `lanplus_rand` are nondeterministic by construction,
  so there is nothing to capture. They are covered by unit tests that assert
  the return-code contract and that successive draws differ, and by inspection
  of the seeding path. See *PRNG* above for the two intentional differences.
* The big-endian branches described under *Endianness*. The generator runs on
  the host, and every machine this project builds on is little-endian, so those
  branches are covered by unit tests that pin the byte order for each host
  endianness plus a reading of the C.
* `lanplus_rakp4_hmac_matches`'s `intelplus` path with SHA-256, which aborts —
  captured in `aborts.txt` rather than `rakp.txt` for that reason.

## Pinning a *length* needs a vector where the candidate lengths disagree

**This is the most important thing in this document. Issue
[#10](https://github.com/cataggar/ipmitool/issues/10) (transports) will hit the
identical problem with checksums and packet lengths, and should use the same
method.**

A vector that asserts only *"correct input produces correct output"* does not
pin a length. If the BMC's authcode is correct in all 20 bytes, comparing 12 of
them and comparing all 20 give the same answer, so no such vector can tell the
two apart. The first version of this port had exactly that hole: the integrity
truncation length was pinned, but the RAKP 4 one was not, and changing it from
12 to 20 left the whole suite green. That constant decides how many bytes of a
BMC's RAKP 4 authcode are checked, so a wrong value there is an
authentication-strength defect that would have shipped as a passing build.

Pinning a length requires an input crafted so that the candidate lengths
*disagree* — for a truncated comparison, an authcode that matches in the first
12 bytes and differs after them. Correct code must answer *match*; any longer
comparison must answer *no match*.

The generalisation used here is a **byte-sensitivity map**. For each byte of an
otherwise-correct authcode the generator flips one bit, asks the C whether it
still accepts, and records `1` if the C noticed and `0` if it did not:

```
rakp4_byte_sensitivity=11111111111100000000     # HMAC-SHA1-96: 12 of 20
rakp4_byte_sensitivity=1111111111111111         # HMAC-MD5-128: 16 of 16
rakp4_byte_sensitivity=11111111111111110000000000000000  # HMAC-SHA256-128: 16 of 32
```

This is better than a single crafted authcode in three ways:

1. It pins the length from **both** sides at once. Too long and the trailing
   `0`s disagree; too short and the leading `1`s disagree. Exactly one length
   satisfies the map.
2. It is **transcription-free**. The map is observed behaviour of the C, not a
   number copied out of `lanplus.h` — so it cannot inherit the same mistake as
   the port it is checking.
3. It needs no knowledge of *why* a byte matters, so it also catches offsets,
   field reordering and off-by-ones, not just truncation.

Maps are emitted for RAKP 2, RAKP 4 (both the `intelplus` and non-`intelplus`
branches) and the integrity check value. See `emit_sensitivity()` in
`tests/crypto/gen_vectors.c` and `expectSensitivity()` in
`src/zig/crypto/vectors_test.zig`.

### The tests must call the shipped code, not re-implement it

The second-order reason the gap survived is that the vector tests originally
*re-implemented* what the exported wrappers do and compared that against the
fixtures. Any constant living only in a C-facing wrapper is then invisible: no
test executes the line it is on.

`src/zig/crypto/test_stubs.zig` fixes this structurally. It provides the four
C symbols the wrappers need to link (`verbose`, `printbuf`, `lprintf`,
`buf2str`, `ipmi_oem_active`) so the **real** exported functions are linked into
the unit-test binary and driven by the vectors. Every one of the 17 exported
symbols except the two PRNG entry points is now called directly by a test. The
stub file `@compileError`s outside `builtin.is_test` so it can never reach a
real link.

### Mutation battery

Every length, offset, constant and comparison in the port was mutated one at a
time and the suite re-run. All of the following now fail:

| Mutation | Caught by |
| --- | --- |
| `Algorithm.authcodeLength` sha1 12→20 / md5 16→8 / sha256 16→32 | `rakp/{sha1,md5,sha256}/admin` |
| `integrityAuthcodeLength` sha1 12→20, md5 16→12, sha256 16→32 (table de-unified) | `rakp/{sha1,md5}/admin` |
| `rakpAuthcodeLength` sha1 12→20, md5 16→8, sha256 16→32 (table de-unified) | `rakp/{sha1,md5}/admin` |
| `intelplusRakpAuthcodeLength` sha1 12→20, md5 16→12 (table de-unified) | `rakp/{sha1,md5}/intelplus` |
| `lanplus_rakp4_hmac_matches` `intelplus` branch forced on / off | `rakp/mix/intelplus-*` |
| integrity hash start offset 4→5 | `rakp/sha1/admin` |
| RAKP-none K1/K2 constant copy 20→19 | `rakp/none/noauth` |
| RAKP 2 / RAKP 3 password key length 20→16 | `rakp/sha1/longuser` |
| SIK Kg key length 20→16 | `rakp/sha1/longuser` |
| RAKP 4 hashed-body length −1 | `rakp` vectors |
| `Algorithm.digestLength` sha1 20→16 | `hmac/01/0/0` |
| K1 constant 0x01→0x02, K2 constant 0x02→0x03 | `rakp/sha1/admin` |
| RAKP session id assembled big-endian | `rakp/sha1/admin` |
| RAKP 2/3/4 `role` ↔ `requested_role` | `rakp` vectors |
| `lanplus_HMAC` copies `length − 1` bytes | `hmac/01/0/0` |
| AES entry point corrupts one output byte | `aes/encrypt/16` |
| AES / confidentiality block size 16→8 | `aes`, `payload` vectors |
| CBC encrypt emits the pre-cipher block | `aes/encrypt/16` |
| `aes_cbc.decrypt` reads its chaining block from the overwritten output | `aes/decrypt-in-place/32` |
| pad fill 1..n → 0..n−1, pad length byte forced to 0 | `payload/aes/0` |
| `padLength` drops the pad length byte | `payload` vectors |
| `payloadLength` drops the pad length byte or stops validating the pad | `payload` vectors |
| `lanplus_encrypt_payload` corrupts the padded input | `payload` round-trip |
| `lanplus_decrypt_payload` `IPMI_CRYPT_NONE` path drops the data | `payload/none/40` |
| `ipmi_auth_md5` uses `out_seq`, or swaps session id and sequence | `auth/md5/*` |
| `ipmi_auth_special` treats the password as 16 fixed bytes | `auth/special/0` |
| `ipmi_auth_md2` returns anything but zeros | `auth/md2/unsupported` |
| `md5_finish` corrupts the digest, `md5` bit count ×8→×4 | `md5/rfc1321/*` |
| `md5_append` zero-length no longer a no-op | `md5/append-zero` |
| `v15_auth` authcode length 16→12, password field 16→12, XOR→OR | `auth/*` |

Lengths that are **not** pinned by a vector, and why that is acceptable:

* `authcode_buffer_size` (20) in `src/zig/intf/intf.zig` and `max_md_size`
  (0x20) in `src/zig/core/ipmi.zig` are hand-written literals, but they are
  field sizes in `extern struct`s that `abi.assertLayout` compares against the
  translate-c'd C structs at compile time. Their *values* are pinned by a
  different, stronger mechanism than a vector. Their *use sites* are pinned by
  the mutations above.
* `lanplus_seed_prng` and `lanplus_rand`: nondeterministic, see
  *What has no vector coverage* above.

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
