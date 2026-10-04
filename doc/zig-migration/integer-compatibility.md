# Integer compatibility profiles (#228 bounded correction)

This leaf corrects integer compatibility, not locale policy or floating-point
parsing. `str2double`, `strtod`, the FP environment and their exports are unchanged.
It does not close #228.

## Verified providers

On the Zig 0.16 toolchain, independently compiled C reproduces the inherited
musl MC discrepancy: `strtol(" ", &end, 10)` returns zero, end offset **1**, and
errno zero. GNU returns zero, end offset **0**, and errno zero. This is not a
translated-header, pointer-arithmetic or test-shim error.

`nm`/`addr2line` locate the bundled musl symbols in Zig's `lib/c/stdlib.zig`,
not upstream musl's `__intscan`. The compatibility profile is therefore named
`zig_0_16`, **not** a claim about every musl installation:

| Case | GNU legacy `strtol`/`strtoul` | Zig 0.16 bundled libc |
| --- | --- | --- |
| No digits after whitespace/sign | End returns to original input | End retains skipped whitespace/sign |
| Overflow followed by more digits | Consume all valid digits | Stop after first overflowing digit |
| Byte classification | Existing process `LC_CTYPE` adapter | Actual provider uses ASCII classification |
| Value/errno on overflow | Signed bound or unsigned maximum, `ERANGE` | Same bounds/errno, different end position |

In particular, original C `str2long("99999999999999999999")` on bundled
musl64 returns `-2`, not `-3`: overflow occurs before the last digit, so the
existing trailing-input precedence wins while errno remains `ERANGE`.
Whitespace-only and sign-only strings can reach the end and return zero status
there. These are verified original-C behaviors, not newly chosen normalization.
Binary prefixes are not enabled in either measured legacy profile; GNU C23
redirected symbols are not silently treated as the legacy API.

## Shared native API

`util/integer_scan.zig` imports neither C nor libc. Its API is:

```zig
scan(T, comptime_radix, bounded_bytes, dialect, comptime_isSpace)
```

`T` is signed/unsigned 32 or 64 bits; radix is zero or 2 through 36 (invalid
radices/types are compile errors). The result supplies `value`, byte `end`,
and `fault` (`none` or `range`). The function does not mutate errno or locale.
It stops at NUL even within a bounded slice. Both dialect and classification
are explicit inputs; injected classification is covered independently.

`dialectForTarget` is the current build adapter: Linux musl ABI selects the
verified Zig 0.16 bundled profile, and the standard/GNU profile is used
otherwise. Alternate/custom libc providers and a changed future Zig runtime
need a separately verified adapter rather than silently blessing new grammar.

`helper.scanInteger(T, radix, sentinel_text)` binds the current profile and
classification. `helper.integerSpace` preserves libc `isspace` for the
standard/GNU provider until native LC_CTYPE is wired; bundled-libc parsing uses
ASCII because its **actual C provider** does. Nothing sets or forces the
production process locale. Existing status, output, narrowing, NULL-argument,
errno-reset and trailing-input precedence remain in the helper adapter.

The current root MC decimal wrapper now calls `helper.scanInteger(c_long, 10,
text)` instead of maintaining a second scanner. Ready MC/LAN worktrees are
untouched. When replaying the MC retirement child, keep this shared wrapper
rather than resurrecting its extracted local scanner. This is the expected
small MC conflict; types/calendar/substrate prerequisites must not be replayed
blindly. Isolated no-libc MC algorithms can use the core API directly with
explicit dialect and classifier; a clock/process API is not involved.

## Independent frozen C evidence

`tests/integer/oracle.c` calls real libc symbols and links the **unmodified**
`lib/helper.c` and `lib/log.c`. It has no Zig scanner/helper implementation.
Three frozen fixtures each contain 1,040 observations plus a profile header:
624 signed/unsigned raw observations (52 inputs, six radices), and 416
original helper status/output/errno observations across all eight integer
entry points. GNU64 and bundled-musl64 were executed on the aarch64 host;
bundled-musl32 was executed as actual ARM code under QEMU, not an LP64 proxy.

The complete focused GNU suite passes 117 tests and the corresponding musl
suite 96. Actual ARM-musl native/C/frozen gates pass seven tests; separately
emitted native GNU/ARM binaries pass the unchanged strict no-libc ELF audit.
Five GNU selectors (ALL, none, helper, mc, mc+helper) preserve all 174 frozen
MC/related-consumer snapshots each, plus 174 C-versus-ALL comparisons.

A disposable archive of ready MC head `01a27632` was adapted to this shared
core without editing that worktree: both GNU and musl pass all **54/54** strict
interop cases and 19 native cases (73 total). Its three formerly GNU-only
native end-offset fixtures also need the verified profile-specific values on
replay: whitespace/sign-only end, positive all-nines overflow end and negative
all-nines overflow end. Actual ARM-musl passes its 19 native cases too. The
archive adapter is integration evidence, not an unnoticed ready-branch edit.

| Frozen file | SHA256 |
| --- | --- |
| `gnu64.tsv` | `5a2b9e181a9131b77aecebc4786ef5094941d3db2cf3cc7b5ca8a91d5c126350` |
| `musl64.tsv` | `d71fe84077e06191199e90f570aa9a5815c2ad576373e8603d8aac7f89102ff7` |
| `musl32.tsv` | `9c2e9a5052f5f684971e60c2b3c33d29656d5079d54402eb9972e5cb8b488f9b` |

Original `lib/helper.c` SHA256:
`fc84f624f5eaa19b39b2be21f694b6613df5cc416bd715b671cfb5e4423b34ec`.
No test recaptures or rewrites fixtures. Source changes require explicit
original-C regeneration/review, not a scanner-produced expected result.

Live interop additionally checks all 256 bytes before digits, after signs,
after zero and after hex prefixes, and all 256 candidate whitespace bytes in
each accepted LC_CTYPE setting. It verifies preserved nonzero errno for raw
successful/no-conversion calls and resets/status/output for all helper calls.
The host actually lists only C/POSIX and C.UTF-8. Bundled musl accepts some
regional locale names without regional data; accepted names are **not**
claimed as proof that such data was installed or exercised. Original locale
is restored after the isolated test process's comparisons.

Focused gates (append reduced feature flags on minimal hosts):

```sh
zig build test-integer-native test-integer-interop test-integer-oracle \
  test-helper-integers test-integer-helper-regressions test-integer-mc \
  test-helper-valstr-unit test-helper-valstr-golden test-cimport-budget \
  -Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false --summary all
zig build -fqemu test-integer-native test-integer-interop test-integer-oracle \
  -Dtarget=arm-linux-musleabihf \
  -Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false --summary all
zig build test-integer-native-compile test-integer-interop-compile \
  test-integer-oracle-compile -Dtarget=arm-linux-gnueabihf \
  -Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false --summary all
```

The ARM command needs `qemu-arm` on its command-scoped PATH. After actual
exit-127 missing-tool evidence, local validation copied the already verified
QEMU 10.2.3 emulator into this worktree's ignored cache; no system install,
registration or ready-worktree modification occurred. Native tests contain
no C module/sources/libc, cover both widths/dialects, and consume all three
frozen raw profiles. GNU32 and little-/big-endian cross ABI compilation are
additional checks, not a claim of GNU32 runtime execution.

Bridge budgets decrease **only** in `helper.zig` (125 to 123 after the floating
parser prerequisites; 121 to 119 on the original leaf base) and `mc.zig`
(285 to 284). The new CPU/interop sources introduce no `ipmi_c` import or
reference. Independent compiled C characterization is not hidden from the
scanner, and no unrelated budget cap is increased.
