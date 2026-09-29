# C/Zig interop seams

This is the contract every later port PR follows. It exists so that replacing
one C translation unit with Zig is a mechanical, reviewable, individually
revertible change instead of an architectural decision.

Related documents: [`baseline-oracle.md`](baseline-oracle.md) for the reference
binaries the golden checks compare against, and issue #2 for the overall plan.

## Module map

The Zig tree mirrors the C tree. Header ports and translation-unit ports are
kept apart, exactly as `include/ipmitool/*.h` and `lib/*.c` are.

| Zig                  | C                                          | Contents |
| -------------------- | ------------------------------------------ | -------- |
| `src/zig/core/`      | `include/ipmitool/ipmi*.h`                 | request/response types, completion codes, session state |
| `src/zig/intf/`      | `include/ipmitool/ipmi_intf.h`, `src/plugins/*` | the transport vtable and the transports |
| `src/zig/cmd/`       | `lib/ipmi_*.c`                             | one module per command translation unit |
| `src/zig/util/`      | `lib/helper.c`, `lib/log.c`, `bswap.h`, `ipmi_time.c`, `ipmi_strings.c` | shared utilities |
| `src/zig/crypto/`    | `src/plugins/lan/{md5,auth}.c`, `src/plugins/lanplus/lanplus_crypt*.c` | hashes, HMAC, AES-CBC and the RMCP+/RAKP layer on `std.crypto` — see [crypto.md](crypto.md) |
| `src/zig/cli/`      | `lib/ipmi_main.c`, `src/ipmitool.c`        | command-line parsing, session setup, dispatch, command table and executable entry point |
| `src/zig/front/`     | `src/ipmievd.c`                             | daemon executable entrypoint, SEL polling and OpenIPMI notifications |

`-Dzig-modules=evd` switches the daemon executable root from the C oracle to
`src/zig/front/ipmievd.zig`. Unlike library ports, this frontend must not be
imported into `exports.zig`: `ipmitool` shares that archive but has its own
`main` and globals. `zig build test-event-daemon` runs hardware-free model
tests, and `test-event-daemon-process` exercises foreground/daemon signals and
PID cleanup with the dummy BMC on Linux when `evd` is selected.

The daemon is a separate Zig executable root, not a member of the
`exports.zig` archive that owns the selected logger's `logpriv`. Its diagnostics
use `src/zig/frontend/logging.zig` through `root.zig`'s frontend import: with
`log` selected, the nonvariadic ABI checks severity in that archive, formats
with C's 1024-byte limit and forwards post-format `errno` for `lperror`. With
the C logger selected, the wrapper calls its original variadic ABI. The daemon
reuses `root.zig`'s import because Zig 0.16 cannot assign the same file to a
second module when the unit-test root also imports the shell frontend. It
imports `util/log.zig` only for level constants; calling its typed logging
functions here would create a second logger state. `build.zig` gives both the
executable and unit-test daemon roots the same module selection as their
linked logger archive. Zig test mode retains the frontend bridge's C-ABI
fallback (which reaches the selected archive via `log_varargs.c`); the
production daemon binaries exercise the nonvariadic path.

On Linux, `zig build test-event-daemon-log -Dipmishell=false` builds the same
Zig daemon with either `evd` or `evd,log`, then byte-compares help/errors,
verbose foreground diagnostics and test-captured daemon syslog. Both binaries
also run the signal/PID lifecycle fixture; the dependent
`test-log-frontends` checks severity filtering, errno and truncation across
the shared-state ABI. On hosts without OpenSSL headers, add
`-Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false`.

Supporting files at the root of `src/zig/`:

| File            | Role |
| --------------- | ---- |
| `ipmi_c.h`      | umbrella header listing which C headers the bridge exposes |
| `abi_layout.h`  | `sizeof`/`alignof`/`offsetof` for C types `translate-c` cannot represent, or represents wrongly |
| `abi.zig`       | comptime layout and signature assertions |
| `root.zig`      | namespace of every header port; the root of `zig build test` |
| `exports.zig`   | link-time root of `libipmitool_zig.a`; one guarded `@import` per port |

`ipmi_c.h` and `abi_layout.h` are build-time scaffolding, never linked into
the product, and are deleted with the last C translation unit.

The generated `util/strings_tables.zig` is data-only: it imports the pure-Zig
`util/table_types.zig` layouts and `build_options.have_crypto_sha256`, not
`ipmi_c` (including transitively). `build.zig` sets that option from the same
`-Dopenssl` switch that defines `HAVE_CRYPTO_SHA256` in `config.h`, even with
LAN+ disabled. `util/strings.zig`'s lookup rules also import only the Zig
tables and layouts; the dynamic registry uses those layouts directly. The
selected export boundary and ABI test root import the separate generated
`util/strings_tables_validation.zig` to check every copied C constant,
exported table element layout and the SHA256 feature against the translated C
header. The table file retains the same C exports and entry order. The
unchanged C implementation remains the golden oracle.

To regenerate both files after changing the C tables or headers, translate
`src/zig/ipmi_c.h` with the same configuration as `build.zig`, then run
`zig run tools/gen_strings.zig -- lib/ipmi_strings.c ipmi_c.zig
src/zig/util/strings_tables.zig`. Repeat with `--check` before the C source
to verify both generated files without writing them. `zig build
test-strings-tables` compiles the data without a C bridge in both SHA256
configurations; `zig build test-strings-lookup-data` runs the lookup tests
without C headers or libc in both configurations. `zig build
test-strings-unit` retains the C-backed ABI checks. `zig build
test-strings-compile -Dtarget=x86_64-linux-musl`
cross-compiles those C header checks without running a foreign test binary.

The two LAN+ lookup tables in `intf/lanplus_strings.zig` also import only
`util/table_types.zig`. Selected exports check every copied status and
privilege constant against the translated C header in a separate validation
module. `test-lanplus-strings` tests the tables without a C bridge and also
compares all exported entries with the C oracle.

### SDR safety across the #53 port

The #53 Zig SDR port originally preceded the issue #42 checks in
`lib/ipmi_sdr.c`. Both `src/zig/cmd/sdr.zig` and the C reader now reject short
Get SDR header/body replies and validate fixed fields and declared name lengths
before returning or caching a record. The checks allow short but complete
names, including a 16-byte name with no in-record NUL. When changing either
reader, rerun the `sen_` golden cases with `-Dzig-modules=sdr,sensor`; C-only
validation cannot protect a swapped SDR build.

### SDR unit-label formatting

SDR unit-label composition now copies bounded Zig slices into the same
41-byte static C ABI buffer. It preserves `snprintf`'s NUL termination,
would-have-written length and truncation, including the 41-character
`% uncorrectable error*uncorrectable error` combination (the final character
is lost). Returned pointers alias the buffer until the next call; sensor
readings, SEL printers and the event daemon still consume the borrowed label
without changes to their request or print paths. `zig build test-sdr-unit-strings`
compares every relation/percentage combination at unit-ID boundaries,
synthetic empty and variable-width digit labels, and capacities 0–48 against
libc. `sd_unit_labels_*` golden cases assert full CLI text, status and request
bytes against C, including percent, multiply, divide and unknown units.
No new out-of-bounds rejection is necessary.

### Kontron OEM / FRU dependency

Selecting `-Dzig-modules=kontronoem` replaces `lib/ipmi_kontronoem.c` and
exports both `ipmi_kontronoem_main` and `ipmi_kontronoem_set_large_buffer`.
It still calls **three public FRU helpers**, declared in `ipmi_c.h` and
provided by `lib/ipmi_fru.c`: `read_fru_area`, `write_fru_area`, and
`get_fru_area_str`. When `ipmi_fru.c` is replaced, its Zig implementation
must export all three with the same ABI; Kontron must not depend on a hidden
C-only FRU shim. `tests/cases/57-kontronoem.cases` records the OEM commands,
the FRU helper request sequences and word-access, and the buffer negotiation
and rollback paths against the original C implementation.

The Kontron C caller indexes its read buffer by absolute FRU offsets although
`read_fru_area` fills it from index zero. The Kontron-specific fixture
intentionally places the serial fields at the positions that caller actually
reads, so byte-level snapshots cover its observable behavior rather than
silently correcting it.
The decoded FRU serial length now uses NUL-aware Zig bytes instead of
libc `strlen`, retaining the public FRU helper's allocation and caller-owned
`free`. `zig build test-kontron-strings` checks lengths, embedded NULs and
serial-size decisions against libc; the `kontron_*` C/selected CLI cases
continue to pin requests, output and status.

## Naming conventions

Same as the sibling project `azure-sdk-for-zig`:

* types and structs: `PascalCase`
* functions and methods: `camelCase`
* constants: `snake_case`
* files: `snake_case.zig`

Two deliberate exceptions, both driven by the ABI:

* **Struct fields keep their C names.** `Response.session.bEncrypted` looks
  wrong in Zig, but `abi.assertLayout` compares field names one for one and a
  reviewer diffing the header against the port should not have to translate.
* **Exported symbols keep their C names**, declared once in a `comptime` block
  with `@export`, so the Zig function itself can stay `camelCase`:

  ```zig
  comptime {
      @export(&setup, .{ .name = "ipmi_oem_setup", .linkage = .strong });
  }
  ```

Runtime interfaces are function-pointer structs recovered with
`@fieldParentPtr`, which is what `intf.Intf` already is in C and what issue #10
will build the Zig transports on.

## The two-way bridge

### Zig calling C: the `ipmi_c` module

`build.zig` runs `zig translate-c` over `src/zig/ipmi_c.h` with the same include
path, `config.h` and `-D` macros a C translation unit gets, and exposes the
result as the `ipmi_c` module:

```zig
const c = @import("ipmi_c");

c.lprintf(log.Level.notice, "\nOEM Support:");
return c.ipmi_sel_oem_init(filename);
```

Every call into remaining C goes through this module — Zig modules do **not**
declare `extern fn` for C symbols. That rule matters: when the module owning a
symbol is itself ported, an `extern fn` declaration would collide with the new
`@export`, whereas a `c.` call site keeps working until the callee's header is
retired.

Bridge types are spelled differently from the mirrors (`[*c]struct_ipmi_intf`
versus `*Intf`), so call sites cast:

```zig
c.ipmi_intf_session_set_authtype(@ptrCast(intf), authtype_oem);
```

That cast is only safe because of the ABI assertions below; do not add one for a
type that has no mirror assertion.

Exposing another header is one `#include` in `src/zig/ipmi_c.h`.

Not every C symbol has a header. `lib/ipmi_raw.c` defines `ipmi_raw_help()` and
`lib/dimm_spd.c` defines `ipmi_spd_print()` and `ipmi_spd_print_fru()`, all with
external linkage but no public prototype. Because `extern fn` is not allowed,
`ipmi_c.h` carries these prototypes so the Zig replacement can check its ABI
and the Zig raw-SPD reader can call the SPD printer. Keep a prototype while
another Zig module uses it or the port needs its C signature for an assertion.

The `dimm-spd` swap replaces the complete printer and FRU reader, including
all twenty externally linked SPD/JEP106 lookup tables. Regenerate the Zig tables
from the original C data with `python3 tools/gen-spd-tables.py`; `--check`
verifies that the generated file is current. The file imports the pure-Zig
`util/table_types.zig` rather than `ipmi_c`; `dimm_spd.zig` checks its `ValStr`
layout against `c.struct_valstr` at compile time and casts only at its
`val2str` call boundary. All 20 generated arrays retain their C export names,
entry order and terminators. `zig build test-dimm-spd-tables` checks the
standalone data without any translated C module. The printer retains the C
output:
the type byte is at index 2 and a file shorter than 92 bytes fails without
output. Otherwise it prints `Memory Type` before checking its type-specific
length:

| SPD type | C field layout | Required bytes | Manufacturer |
| --- | --- | ---: | --- |
| `0x0b` DDR3 | density/banks, bus/device widths, ranks, voltage/ECC, date, 18-byte part | 148 | bank/code at 117/118 |
| `0x0c` DDR4 | package/technology, 3DS logical ranks, density, widths, voltage/ECC, date, 20-byte part | **349** | bank/code at 320/321 |
| all other types (including DDR, DDR2 and unknown types) | legacy size/voltage/ECC, optional 18-byte part, serial | 100 | `0x7f` continuations at 64–71, code through 72 |

The original C DDR4 check accepted 348 bytes, then read part-number byte 348
out of bounds; both implementations now require 349. Manufacturer banks 0–8
use the original JEP106 tables; newer DDR3/DDR4 banks print
`JEDEC JEP106 update required`.
The C decoder does not validate SPD-header byte counts or JEDEC CRCs; the Zig
decoder intentionally does not discard otherwise readable SPD images on those
grounds. The original C FRU wrapper read 16-byte chunks but ignored the decoder's
return status and could spin on a successful zero-byte read. Both wrappers
validate Get FRU Info and Read FRU Data response lengths before accessing
them, reject a zero-byte read, and propagate truncation errors. No-response
and completion-code messages, including the distinct `0xc3` timeout return
value of 1, stay unchanged. The SPD printer's stdout formatting now uses a
Zig 0.16 streaming writer: it calls the shared `util/stdout.zig` `trySyncC()`
to check `fflush(stdout)` before output and again after FRU callbacks, then
checks both Zig writes and the final writer flush.
Failures log a `LOG_ERR` message distinguishing C preflush, C flush after
FRU callbacks, Zig write, and Zig final-flush phases, then return `-1`
through the unchanged C ABI (overriding a normal or distinguished timeout
result only when a new output failure occurs); the verbose `printbuf`
remains on stderr.
DDR3/DDR4 part bytes, including embedded NULs, are emitted verbatim, while
the legacy `%s` part ends at its first NUL. C-backed DDR2/DDR3/DDR4 outputs
and malformed FRU cases are pinned in `tests/cases/57-dimm-spd.cases`.
Run `zig build test-dimm-spd-unit` for decoder boundaries, byte-exact writer
formatting and write failures, and JEP106 table tests independently of the
unrelated crypto-vector unit tests.

### C calling Zig: `export` with the original signature

A ported module defines the symbols the C used to define, with identical C ABI
signatures, and `build.zig` drops the `.c` from the compile. The remaining C is
unchanged and unaware — this is a pure link-time substitution.

```zig
fn active(intf: ?*Intf, oemtype: ?[*:0]const u8) callconv(.c) c_int { ... }

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(active), @TypeOf(c.ipmi_oem_active));
    @export(&active, .{ .name = "ipmi_oem_active", .linkage = .strong });
}
```

`src/zig/exports.zig` calls `exportSymbols()` from a `comptime` block guarded by
`-Dzig-modules=<name>`. Put the assertion *inside* that function rather than in
a file-scope `comptime` block: naming a C declaration emits a reference to it,
and a file-scope reference is analysed even when the module is not selected,
which the self-hosted x86_64 backend reports as `undefined symbol: ... note:
referenced by root.o:.debug_info` on `test (ubuntu-latest)` only. See
doc/zig-migration/varargs-trampoline.md.

`abi.assertCallSignature` compares the calling convention, the variadic flag,
the argument count and the size/alignment of every argument and of the result
against the `translate-c` view of the real prototype. A header change that the
port does not follow is a compile error.

### PICMG and the FRU port

`-Dzig-modules=picmg` replaces all of `lib/ipmi_picmg.c`. Its exported command
functions, argument validators, discovery helpers, `picmg_led_color_str` and
`amcAddrMap` retain their C names and ABI. PICMG functions absent from
`include/ipmitool/ipmi_picmg.h` are declared in `ipmi_c.h` for compile-time
signature checks. The PICMG port calls `is_fru_id` through the shared helper
ABI and decodes FRU link-descriptor bitfields from checked wire bytes; it does
not depend on whether `lib/ipmi_fru.c` has been swapped for a Zig FRU port.
`tests/cases/57-picmg-depth.cases` records the C requests, output and errors
for this seam before substituting the PICMG translation unit.

## The swap flag

```
zig build                        # all C, byte-identical to the oracle
zig build -Dzig-modules=oem      # lib/ipmi_oem.c replaced by src/zig/cmd/oem.zig
zig build -Dzig-modules=vita     # lib/ipmi_vita.c replaced by src/zig/cmd/vita.zig
zig build -Dzig-modules=oem,raw  # several at once
zig build -Dzig-modules=lanp,channel,user  # LAN configuration and its helpers
zig build -Dzig-modules=lanp6    # IPv6 LAN configuration (see lanp6.md)
zig build -Dzig-modules=lanplus-strings # LAN+ lookup tables, no C table object
zig build -Dzig-modules=ekanalyzer # offline FRU/PICMG eKey analyzer
zig build -Dzig-modules=cli      # use Zig for both the shared CLI and ipmitool main
zig build test-cli               # diff C and Zig CLI, including PTY/SIGINT tests
zig build -Dzig-modules=pef      # lib/ipmi_pef.c replaced by src/zig/cmd/pef.zig
zig build -Dzig-modules=sunoem   # Sun/Oracle ILOM commands, including LED SDR lookups and CLI
zig build -Dzig-modules=all      # every registered Zig replacement in both installed binaries
zig build --help                 # lists the available module names
```

`all` is a selection alias, not a pure-Zig switch: the logging varargs shim,
translated C headers and libc still remain. The default C build continues to
serve as the golden oracle until the Phase 7 cutover.

The selected IANA registry keeps its C ABI pointer, but its value array and
registry names share a Zig arena reclaimed by `ipmi_oem_info_free`. Registry
files are opened and streamed with Zig I/O, including non-seekable files; the
user registry still takes precedence over the system registry. Common open
and read errors retain their `errno`/`perror` diagnostics, while other Zig
open errors report their name explicitly. Line iteration, enterprise-number
parsing and bounded path joins live in header-free `util/registry_parse.zig`;
`zig build test-registry-parse` checks their newline, saturation and truncation
boundaries without libc. `HOME` lookup and error reporting still call libc.
The C oracle retains its original `malloc`/`free` and stdio.

The selected `helper.zig` scans six width-two MAC fields in Zig and formats
the `Unknown (0x...)` fallback with `std.fmt`. Unit tests keep libc
`sscanf`/`snprintf` as oracles, including every two-byte pair in each field
and the full 16-bit fallback range; the invalid-MAC diagnostic and value
fallbacks remain golden-tested. General numeric parsers and printf-style
formatting paths still use libc.

**Intentional MAC deviation:** Zig always rejects a width-two incomplete
`0x`/`0X` prefix, leaving the output buffer unchanged and reporting the usual
invalid-MAC error. libc's behavior for this prefix changed across versions.
The *same* binary linked to
`sscanf@GLIBC_2.17` parses `0x:00:00:00:00:00` as six zero bytes on Ubuntu
24.04 glibc 2.39, but returns no conversions on glibc 2.43; musl also returns
no conversions. With `00:00:00:00:00:0Xf`, glibc 2.39 accepts six zero bytes
but glibc 2.43 and musl stop after five conversions. A fixed libc-free scanner
cannot emulate both runtime libc versions. This narrowly scoped difference
from the C oracle on glibc 2.39 is accepted for the selected Zig helper; no
other MAC inputs are exempted from libc differential checks. The tests compare
all other two-byte field pairs against libc, and for the incomplete-prefix
cases assert that Zig rejects without writing while libc either rejects or
produces the exact expected bytes. The C oracle and golden snapshots remain
unchanged.

The selected helper writes `printbuf`'s verbose hex dump through Zig stderr
I/O instead of libc `fprintf`. Sixteen-byte line wraps and header/hex bytes
remain golden-tested; a failed write terminates explicitly.

The selected OpenIPMI transport writes its verbose request, conversion,
encapsulation, received-message and decapsulation diagnostics through a Zig
stderr writer. Before each diagnostic group it checks `fflush(stderr)` to
preserve preceding buffered C logger and `printbuf` output; it also checks
the Zig write and final flush before the next C output. These failures
terminate explicitly rather than silently returning a successful response.
The existing C `printbuf` and `buf2str` calls, ioctl protocol, and the
original C transport are unchanged. In particular, `Got message:` still
shares its line with `type`, and a signed negative channel retains the C
`%x` promotion to unsigned 32-bit. `zig build test-open-verbose-stderr`
byte-compares the original C and selected Zig ABI under fully buffered C
stderr, with direct and bridged simulated ioctl replies at verbosity 2, 3,
4 and 5, including interleaved logger and printbuf output. `test-fdset`
also tests the OpenIPMI model and early/late writer failures. Without local
readline/OpenSSL headers, run both with `-Dipmishell=false -Dopenssl=false
-Dinternal-md5=true -Dintf-lanplus=false`.

The selected OpenIPMI transport now formats its three `/dev/ipmi*` node
names into the original fixed-size arrays with bounded Zig formatting.
Names that fit remain byte-identical to libc and retain the original
fallback order, flags and error diagnostic. The `devnum` ABI is an unsigned
byte, so every representable number fits; the bounded formatter explicitly
rejects hypothetical wider or negative out-of-range inputs rather than
overflowing a buffer. `zig build test-open-device-path` compares
NUL-terminated paths with libc at decimal-width boundaries, checks this
bound and exercises the maximum ABI value through the model driver.
`test-fdset` exercises the remaining model-driver fallback.

The selected AMI USB SCSI transport formats `/dev/sgN` paths with bounded
Zig formatting rather than libc `sprintf`. `zig build test-usb
-Dzig-modules=usb` compares path bytes with libc across signed `c_int`
boundaries, rejects a short destination, and retains the model SCSI device's
discovery and descriptor-lifetime checks. The C USB transport is unchanged.

For `loglevel < 0`, the selected `print_valstr` and `print_valstr_2col` write
through Zig's streaming stdout writer. They first check `fflush(stdout)` to
drain any preceding libc `printf` output, then check both Zig writes and the
writer's final flush; failures terminate explicitly rather than returning a
successful `void` call. Subsequent C output remains after the Zig bytes.
The title, header, decimal and minimum-width hex fields, byte-counted
32-column padding (including UTF-8), and trailing blank lines retain their
C layout. `%d` on the original unsigned table values renders their signed
32-bit interpretation, including values above `INT_MAX`. The `loglevel >= 0`
logging path is unchanged, and the original `lib/helper.c` remains the C
oracle. `zig build test-helper-valstr-unit` compares zero/short/long/odd
tables, 255/256 and width boundaries with libc `snprintf`, and tests early
and late writer failures. `zig build test-helper-valstr-golden` runs the
same C caller against both original and selected helpers, pinning both
stdout variants with buffered C output before and after each table. CLI
goldens `raw_missing_args` (one-column logging path) and `sd_entity_list`
(two-column stdout path) additionally cover the selected tool. On hosts
without readline/OpenSSL headers, use `-Dipmishell=false -Dopenssl=false
-Dinternal-md5=true -Dintf-lanplus=false`.

The selected CLI's `-V` and `-z` output uses the shared Zig stdout writer in
`util/stdout.zig`. It checks a libc stdout pre-flush to preserve preceding C
output and propagates Zig write and flush failures. The helper's value-table
stdout path reuses that pre-flush. SIGINT diagnostics still use the legacy
C stdio path pending the signal-handler cutover.

The shell echo/set stdout paths call its checked `trySyncC` variant and return
`-1` with a log diagnostic on flush failure; CLI/helper keep `syncC`'s panic.

The selected `raw` command's response hex dump uses the same checked Zig
streaming writer. It checks `fflush(stdout)` before the first byte so libc
output buffered by a caller stays ahead of the response, then checks writes
and the final flush, returning `-1` with a diagnostic on failure. The
lowercase, zero-padded two-digit bytes retain their leading space, wrap
after every sixteen bytes, and always end in a newline, even for an empty
response. `i2c` parsing, the C ABI and the original C oracle remain
unchanged. `zig build test-raw-output` compares lengths 0 through 1024 at
wrap boundaries against libc `%2.2x` formatting, runs the same C caller with
buffered output before and after the original C and selected Zig commands,
and exercises early and late writer failures. The `raw_` CLI goldens pin
response and verbose ordering with `-Dzig-modules=raw`. Use the
reduced-feature flags above if needed.

The selected `i2c` command now uses a checked Zig streaming stdout writer
for its conditional `Wrote`/`Read` lines, lowercase 16-byte-wrap hex dump,
and bit strings for replies of at most four bytes. It preserves the C
`printbuf` diagnostic before the transfer, uppercase two-digit device
address, spaces and newlines, and returns `-1` for a short read *after* any
applicable summary lines, without dumping that reply. It checks libc stdout
pre-flush (so earlier C output stays ahead of Zig output), Zig writes, and
the final flush, logging the failed phase and returning `-1`. When C would
print nothing (no read/write, or a quiet mixed short read), it preserves the
status without touching stdout. `zig build test-raw-i2c-stdout` compares
C-formatted boundaries and all summary modes, short replies, buffered C/Zig
ordering, and injected pre-flush, early/late write and final-flush failures.
The `i2c_*` C/selected Zig CLI goldens cover real dummy-interface responses
with `-Dzig-modules=raw`.

The selected `gendev read` and `gendev write` commands stream the locator
announcement and EEPROM progress/completion lines through checked Zig stdout.
Each line pre-flushes libc stdout before the Zig write and checks its final
flush, preserving order around C SDR lookup output and retaining the original
carriage returns, partial-read error text and literal `%100` on completion.
On any pre-flush, write or final-flush failure, the command logs the failed
phase and returns `-1`; read/write progress failures also stop the transfer
and close the open C file without printing a misleading completion line. The
SDR, I2C and file data paths remain in C. `zig build test-gendev-stdout`
checks C formatting boundaries, mixed C/Zig ordering, and injected stdout
failures. The `gd_*` C/selected-Zig CLI goldens cover successful transfers,
lookup failures and early errors; the new `gendev_*_partial_error` C-recorded
cases also pin the progress line before a late read/write failure at 43%.
Run the existing cases with `zig build test-golden -Dzig-modules=gendev --
--filter gd_`; select either late-error case by its full name with `--filter`.
On hosts without readline/OpenSSL headers, add `-Dipmishell=false
-Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false`.

Only the selected ISOL `info` printer uses a checked Zig stdout writer; the
interactive SOL session and all other ISOL paths still use their original C
stdio. It flushes libc stdout before writing so previously buffered C output
stays ahead of the info response. CSV retains its final comma without a
newline; human output retains all three labels and newlines. Privilege and
bit-rate values are looked up as each field is written, since C's unknown
value fallback uses one shared static buffer. Pre-flush, Zig write and final
flush failures log at error severity and return an error (`-1` from the
command) instead of reporting success. `zig build test-isol-info-stdout`
compares both formats and representative strings against libc `snprintf`,
tests the shared fallback, mixed C/Zig output ordering, and injected early,
late, pre-flush and final-flush failures; it is also part of `zig build test`.
The original C implementation and the `isol_info_*` CLI snapshots remain
parity oracles. Run those with `zig build test-golden -Dzig-modules=isol --
--filter isol_info_`; without local readline/OpenSSL headers, add
`-Dipmishell=false -Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false`.

The selected `user summary` command streams CSV and human-readable counters
through checked Zig stdout after flushing buffered C output. It retains the
three unsigned decimal fields, spacing, tabs and newlines, and returns `-1`
with a diagnostic on pre-flush, write or final-flush failure. `zig build
test-user-summary-stdout` compares representative counter boundaries with
libc formatting, checks mixed C/Zig stdout order and injects early and late
write and flush failures; the
`user_summary_*` CLI goldens compare the original C command and selected Zig
on both CSV and human output with real dummy-interface responses.

The selected `user list` printer streams the C-compatible header and rows
through checked Zig stdout, preserving byte-width padding (including the
human-mode boolean spaces), the shared privilege fallback and the header's
process-lifetime, human-only once flag. It checks libc stdout before each
row and flushes each row before fetching the next user, retaining prior rows
if a later request fails. Preflush, write or final-flush errors log their
phase and return `-1`. `zig build test-user-list-stdout` compares libc bytes
for blank, 16-byte and non-ASCII names, bit combinations and unknown
privileges; it tests repeated invocations, C/Zig buffered order and I/O
failures. The `user_list_*` C/selected-Zig goldens include an error after
two rows in both modes. Other user command output is unchanged.

The selected `mc selftest` command uses a checked Zig stdout writer for all
result codes, retaining the original messages, hexadecimal case and padding,
bitwise failure ordering, no-newline reserved result, and exit statuses.
It pre-flushes buffered C output and checks both Zig writes and the final
flush; failures log an error and return `-1`. `zig build
test-mc-selftest-stdout` compares formatting and statuses, including libc
hexadecimal output at width boundaries, mixed C/Zig output ordering, and
pre-flush, early/late write and final-flush failures. The existing
`mc_selftest_*` C/selected-Zig CLI goldens cover all result branches.

The selected `chassis selftest` result streams through checked Zig stdout
after pre-flushing buffered libc output. It preserves the C labels, bit order,
lowercase hex and success/request-error statuses; any pre-flush, write or final
flush failure logs its phase and returns `-1`. `zig build
test-chassis-selftest-stdout` checks C-byte parity across all self-test bits,
buffered C/Zig ordering, request errors and injected I/O failures. The
existing `chassis_selftest_*` original-C and selected-Zig CLI goldens retain
the wire and output oracle.

The selected `chassis identify` acknowledgement also uses checked Zig stdout,
preserving the default/force/off/numeric messages and their request lengths and
statuses. It pre-flushes libc stdout before writing, checks the final flush,
and logs and returns `-1` on any output failure. `zig build
test-chassis-identify-stdout` compares C bytes, buffered output order, request
statuses and injected I/O failures. The existing `chassis_identify_*` CLI
goldens retain the C wire/output oracle.

The selected `chassis status` display streams checked Zig stdout after a
libc pre-flush. It preserves the C labels, restore policy and event ordering,
trailing spaces, and the optional front-panel rows at exactly the same
response-length boundary. Request failures stay unchanged; pre-flush, write
or final-flush failures log their phase and return `-1`. `zig build
test-chassis-status-stdout` compares libc bytes across flag and length
boundaries, mixed C/Zig output and injected I/O failures. The existing
`chassis_status*` original-C and selected-Zig CLI goldens retain the wire and
output oracle.

The `chassis power status` and top-level `power status` success line also uses
checked Zig stdout after a libc pre-flush. Its exact `Chassis Power is on/off`
bytes and low-bit interpretation match C; request and completion-code errors
still return `-1` without writing. Pre-flush, early/late write and final-flush
errors log their phase and return `-1`. `zig build
test-chassis-power-status-stdout` compares C bytes, response statuses,
buffered C/Zig order and injected output failures; the `chassis_power_status*`
and `power_status*` original-C/selected-Zig goldens check both command routes.
The selected `chassis poh` result also streams checked Zig stdout with a
libc pre-flush. Its existing single-precision count arithmetic, C wording,
minutes-field threshold and request behavior stay unchanged; output failures
log their phase and return `-1`. `zig build test-chassis-poh-stdout` checks C
bytes, request statuses, buffered output order and injected failures; the
`chassis_poh*` C/selected-Zig goldens cover the float precision boundaries.
When chassis is Zig, `test-shell` additionally builds a test-only hybrid with
**C chassis** and Zig shell/MC to retain a genuinely C-buffered POH pre-flush
probe. The selected-chassis shell separately checks that a Zig POH write
failure on `/dev/full` is not reported as success.

The selected `chassis restart_cause` result likewise pre-flushes buffered C
stdout before checked Zig writes and final flush, preserving all masked
codes, table lookups, newline and request status. Output errors log their
phase and return `-1`. `zig build test-chassis-restart-stdout` compares C
bytes across all cause bytes and checks buffered ordering and failure
injection; the existing `chassis_restart_cause*` C/selected-Zig CLI goldens
keep the oracle.

The selected `chassis bootparam get` and `chassis bootmbox get` results now
pre-flush libc stdout and stream checked Zig output for generic fields,
decoded boot flags and mailbox blocks. Hex dumps preserve C's lowercase
bytes and `buf2str` size limit; the mailbox keeps its block column alignment,
PEN lookup and embedded-NUL text behavior. The `chassis bootdev` and
`chassis bootparam set bootflag` success acknowledgment also uses checked
Zig stdout, preserving the set-complete request even if output fails.
Pre-flush, write and final-flush failures log and propagate through the
multi-block read instead of being mistaken for the normal end-of-mailbox
response. `zig build test-chassis-bootparam-stdout` checks C hex and
acknowledgment parity, request and output status, mixed C/Zig ordering,
cleanup requests and failure injection. The existing `chassis_bootparam_get*`,
`chassis_bootdev_*` and `chassis_bootmbox_*` C/selected-Zig goldens cover every
parameter, boot option and single/multi-block output.

The selected `chassis bootmbox get` request selector strings now use bounded
Zig formatting instead of libc `snprintf`. The caller-owned two- and four-byte
arrays remain NUL-terminated, and explicit block numbers still truncate to
`uint8_t` before decimal formatting. Requests retain their three-byte data,
status, 0-through-255 block order, output handling and end-of-mailbox behavior.
`zig build test-chassis-mailbox-requests` compares all selector bytes and
buffer tails against C, including signed/out-of-range blocks, and checks
single/all-block ordering and status propagation. The
`chassis_bootmbox_get*` C, selected and all-selected CLI goldens also compare
the on-wire request bytes. Mailbox SET, stdout printers and POH are unchanged.

The selected `chassis bootparam set bootflag options=...` and `chassis
bootdev ... options=...` paths now split comma-separated options in Zig rather
than libc `strtok_r`. Like C, the scanner skips empty tokens, stops at the
first NUL, and writes NULs over only the delimiters reached; the caller's
writable argument and the no-comma help literal retain their lifetimes and
mutations. `zig build test-chassis-comma-tokens` compares token addresses,
bytes and complete argument mutations with libc across every byte and
delimiter boundary, then checks option masks. Existing original-C, selected
and all-selected boot option goldens retain request bytes and exit statuses.

The chassis command dispatch, bootflag and bootdev option names and prefixes,
and text mailbox length now use NUL-terminated Zig slices rather than libc
`strcmp`, `strncmp` and `strlen`. Prefix matching still requires the entire
prefix, reads stop at the first NUL, and writable options keep their in-place
token mutations. `zig build test-chassis-cstrings` compares equality, prefix
decisions and byte lengths with libc across every first byte, shorter/longer
names and embedded NULs; the chassis CLI goldens cover command and request
statuses.

The remaining chassis boot-parameter SET debug hex and mailbox SET info hex
diagnostics call the Zig helper formatter directly, rather than the C
`buf2str`/`buf2str_extended` ABI. It keeps C's lowercase digits, optional
spaces, 3073-byte static buffer, truncation at whole-byte/separator boundaries,
NUL termination and next-call overwrite; each pointer is consumed
synchronously by the logger. `zig build test-chassis-log-hex` compares every
byte against libc `snprintf` and checks both truncation limits, including
buffer reuse. Original-C, selected-chassis and all-selected CLI goldens cover
verbose diagnostics and the unchanged mailbox request/acknowledgment order.
Other C parsing, lookup and logging seams are unchanged.

The selected `chassis power on/off/cycle/reset/diag/soft` (and top-level
`power`) success messages now use checked Zig stdout. Their original
value-table wording, newline, request and error behavior remain unchanged;
pre-flush, write or final-flush failures log and return `-1`. `zig build
test-chassis-control-stdout` checks byte parity for all control bytes, request
statuses, C/Zig buffered order and injected I/O errors. The existing
`chassis_power_*` and `power_*` C/selected-Zig goldens retain the CLI oracle.
The `chassis policy list/always-on/always-off/previous` result also uses
checked Zig stdout after a libc pre-flush. Its ordered support bits and
trailing spaces match C, including an empty support mask; it preserves the
request and completion-code statuses and logs/returns `-1` on output errors.
`zig build test-chassis-policy-stdout` compares C bytes for every support
mask and policy byte, buffered C/Zig order, statuses and injected failures;
the `chassis_policy_*` C/selected-Zig goldens keep the CLI oracle. Chassis help
and diagnostics remain on their existing logger path.

The selected MC warm/cold reset acknowledgement also streams through checked
Zig stdout after a libc pre-flush. Its words, newline and command status
match C; pre-flush, write and final-flush failures log and return `-1`.
`zig build test-mc-reset-stdout` compares C formatting, buffered C/Zig
ordering and injected failures. The existing `mc_reset_*` original-C and
selected-Zig CLI goldens cover both successful reset variants and errors.

The selected `mc watchdog off` and `mc watchdog reset` success acknowledgements
also use checked Zig streaming stdout with a libc pre-flush. Their messages,
newlines and success statuses match C, while pre-flush, write and final-flush
failures log the phase and return `-1`; requests, completion-code errors and
other watchdog output are unchanged. `zig build test-mc-watchdog-stdout` checks C
byte parity for both messages, mixed buffered C/Zig ordering and injected
pre-flush, early/late write and final-flush failures. The existing
`mc_watchdog_off*` and `mc_watchdog_reset*` C/selected-Zig goldens cover the
success and error responses.

The selected `mc watchdog get` result also uses checked Zig streaming stdout
after pre-flushing libc stdout. Its field labels, table names, masked lookup
indices, expiration-flag rows, status and IPMI request match the C command;
countdowns render every `u16` tick count as exact decimal tenths with libc's
locale decimal point, avoiding architecture- or FMA-dependent float rounding.
The static watchdog table names remain borrowed through their writes. A
pre-flush, write or final-flush failure logs its phase and returns `-1`, while
request and completion-code errors still return without attempting output.
`zig build test-mc-watchdog-get-stdout` compares libc bytes across the flag
and table paths and every countdown, buffered C/Zig ordering, request statuses
and injected output failures. The original-C and selected-Zig
`mc_watchdog_get*` goldens retain the CLI and wire-level oracle. Watchdog
set/off/reset and other MC paths are unchanged by the GET output cutover.

The selected `mc watchdog set` `t=`/`p=` values now use a Zig signed-decimal
scanner instead of libc `strtol`. It skips whitespace according to the active
C locale's `isspace`, accepts an optional sign and ASCII decimal digits, and
returns the original offset on a conversion with no digits (including after
leading whitespace/sign). It consumes every digit after overflow, saturates
to the target's `LONG_MIN`/`LONG_MAX` for the existing `%ld` range diagnostic,
and rejects trailing junk before checking the 1-6553/1-255 bounds. Requests,
watchdog GET output and nonnumeric options are unchanged. `zig build
test-mc-watchdog-numeric` compares consumed offsets and values against libc
across the byte alphabet and numeric boundaries, and checks SET request bytes
and statuses; the `mc_watchdog_*` CLI goldens provide the original-C oracle.
Non-C locales may define additional non-ASCII digits for `strtol`; those
implementation-defined numeric alphabets are outside this ASCII-decimal
scanner's scope, while locale-specific whitespace remains supported.

The selected helper's `str2long`/`str2ulong` now scan base-zero signed and
unsigned integers in Zig, preserving C `isspace` for the active locale and
the original `errno`, saturation, no-conversion, trailing-input, and
negative-unsigned rules. `zig build test-helper-integers` compares values,
return codes, and `errno` with libc across all first-byte inputs and
overflow/prefix boundaries. Non-ASCII locale-specific numeric alphabets
remain a documented difference; `str2double` still uses libc.

The selected `picmg properties` success result now streams its four lines
through checked Zig stdout: a libc stdout pre-flush preserves prior buffered
output, and writes and the final flush are checked. The identifier, extension
version nibbles, maximum FRU ID and FRU ID retain C's exact `%02x` and `%i`
bytes, labels, order and newlines. Discovery and other PICMG subcommands still
make their original properties requests silently, and failed/short responses
return `-1` without stdout. Output failures log the phase and return `-1`.
`zig build test-picmg-properties-stdout` compares libc bytes for each response
field across all 256 values, silent and error statuses, buffered C/Zig ordering
and injected writer failures. The `picmg_properties_stdout_*` cases in
`tests/cases/58-picmg-properties-stdout.cases` pin original-C snapshots for
success boundaries and completion-code failure, including request bytes.
Unlike the C oracle's unchecked short-response read, the existing Zig
length guard still rejects replies shorter than four bytes.

Watchdog option splitting now scans the NUL-terminated argument in Zig
instead of calling libc `strchr`. It still selects the first `=`, returns a
pointer immediately after it (including an empty value), and ignores bytes
after the first NUL. `zig build test-mc-watchdog-equals` compares pointers
and value bytes with libc across all byte values and checks real SET request
bytes and failures; existing C/selected-Zig watchdog CLI goldens cover the
command path.

The selected `mc info` device-ID printer now streams its human-readable
fields through checked Zig stdout, pre-flushing libc stdout before writing
and checking every write and the final flush. The labels, decimal and
hexadecimal widths, optional product name, ordered support bits and exact-
length auxiliary firmware section follow the original C printer. Manufacturer
and product lookups still use the C tables, consuming each shared unknown-name
buffer before the next lookup. Any output failure logs its phase and returns
`-1`; BMC request and response errors retain their existing behavior.
`zig build test-mc-info-stdout` compares libc bytes at each field, optional
sections and unknown lookups, buffered C/Zig order and injected I/O failures.
The existing `mc_info*` original-C and selected-Zig CLI goldens in
`41-mc.cases` and `30-commands.cases` retain the C oracle.
The device-ID manufacturer and product names now use the Zig value-table
helpers, not the C `val2str`/`oemval2str` calls and their libc `snprintf`
unknown fallback. They still read the live IANA registry and ordered product
table, preserve first-match and PICMG-wildcard rules, stop at their sentinels,
and render `Unknown (0xNN)` with C's minimum two-digit uppercase hex. The
shared fallback buffer is consumed by the writer before the product lookup
overwrites it. `zig build test-mc-info-names` checks known C-formatted name
bytes, embedded NULs and duplicate/terminator rules, and compares the 32-byte
fallback buffer with libc formatting through the `u32`/`u16` boundaries;
`mc_info*` original-C, selected-MC and all-selected goldens pin the request,
status and printed names.
For MC reset, global enables, device ID and selftest, completion-code names
also use the Zig table lookup and bounded unknown formatter rather than C
`val2str`. Watchdog and system-info status paths retain their previous
implementation. `zig build test-mc-completion-names` checks precedence,
NUL termination, all byte-sized unknown codes and the full zero-filled
fallback against libc; `mc_info_unknown_ccode` adds the original-C CLI oracle
for a two-digit unknown code and its error status, alongside the existing
known-code MC goldens. Other MC lookup paths are unchanged.

The selected `mc getenables` and `mc setenables` output now uses checked Zig
streaming stdout. The seven flag rows retain C's 40-byte left alignment,
reserved-bit gap, mask order and enabled/disabled text; setter progress,
verification and no-change lines retain their exact newlines. Each output
phase pre-flushes buffered libc stdout and checks its write and final flush.
An output failure logs the phase and returns `-1`, including failures in the
verification get called by the setter. Requests, parsing, and partial output
before a later invalid option or request failure remain unchanged. In
particular, the legacy setter still returns `0` if the verification *request*
fails after successful set/no-change, but no longer ignores verification
*output* failures. `zig build test-mc-enables-stdout` checks C byte parity,
mixed buffered output, statuses and injected I/O failures. The existing
`mc_getenables*` and `mc_setenables*` original-C/selected-Zig CLI goldens cover
successful and rejected requests and option parsing. Other MC output remains
on its existing path.

The selected `mc guid` printer now pre-flushes buffered C stdout and streams
the GUID, optional auto-detected encoding/warning, version and timestamp
through checked Zig writes with a checked final flush. It preserves C byte
formatting and the original GUID request, completion-code and short-response
statuses. The C ABI `ipmi_guid2str()` helper now formats into a bounded Zig
buffer and copies the NUL-terminated bytes to the caller's buffer, without
libc `sprintf` or `buf2str`; it returns the same parsed struct by value and
never exposes temporary Zig storage. Hex dump and canonical GUID spellings
match C, including case, field widths and byte ordering. The timestamp
formatter `ipmi_timestamp_numeric()` remains C, with transient strings copied
before further C lookups.
Pre-flush, write or final-flush failure logs an error and returns `-1`.
`zig build test-mc-guid-stdout` compares libc bytes across explicit, automatic
and dump modes, version and time formatting, request statuses, buffered C/Zig
order and injected I/O failures; it also checks the helper's C-format bytes,
buffer lifetime and output bounds across every raw-byte position and value.
The existing `mc_guid*` original-C and
selected-Zig CLI goldens in `tests/cases/41-mc.cases` cover the real dummy
interface, including explicit and detected modes and error responses. Other
MC output is unchanged.

The selected `mc getsysinfo` output uses checked Zig streaming stdout for
both the verbose selector triple before each request and the assembled GET
value after the read loop. `%.2x` minimum-width hexadecimal formatting,
raw payload bytes up to the first embedded NUL, the trailing newline (even
on a request or completion-code error), block/encoding/length boundaries and
original request statuses match C. Each emission pre-flushes libc stdout and
checks writes and final flush; a failure logs its phase and returns `-1`
without continuing requests or claiming success. `mc setsysinfo` has no
success acknowledgement in C and remains silent. Its SET packet assembly
now uses Zig byte length and copies only the logical string bytes into each
zeroed 18-byte block instead of libc `strlen`/`strncpy`. The original signed
length clamp, low-byte advertised length, 14/16-byte progression, padded
request bytes and error statuses remain unchanged. `zig build
test-mc-sysinfo-set-copy` compares full requests with libc across length
boundaries, early NULs and midstream failures; `zig build
test-mc-sysinfo-stdout` covers libc byte parity, buffered C/Zig order,
GET/SET request and status behavior and injected
pre-flush, early/late write and final-flush failures. Original-C and
selected-Zig `mc_getsysinfo*`/`mc_setsysinfo*` goldens remain the CLI oracle,
including GET length 14/254/255 and embedded-NUL values; the GUID formatter
and GET system-info assembly are unchanged.

The selected MC dispatch, GUID modes, global-enables values, watchdog literal
options and system-info parameter names now compare typed NUL-terminated Zig
byte slices instead of calling libc `strcmp`. The original argument guards,
selector ordering, case sensitivity, embedded-NUL behavior, request bytes
and statuses remain unchanged; watchdog option splitting, numeric parsing
and system-info SET copies are separately covered above. `zig build test-mc-strcmp`
compares libc equality for every byte and string-length boundaries, checks
watchdog and system-info selectors, and exercises real SET requests and
response statuses. Existing original-C, selected-MC and all-selected
`mc_*`/`bmc_*` CLI goldens cover dispatch throughout the command tree.

The selected `session info` printer also pre-flushes C stdout, then streams
both human and CSV response fields through a checked Zig 0.16 writer with a
checked final flush. It preserves the C labels, byte ordering, decimal/hex
format, trailing blank line in human mode, and the length-specific 3-, 12-,
14- and 18-byte layouts (including zero-filled short replies). A pre-flush,
write or final-flush failure logs its phase and returns `-1`; a successful
query still returns `0`. Other session request and completion-code behavior
is unchanged. `zig build test-session-info-stdout` runs boundary-format and
injected I/O failure tests plus a differential CLI fixture against original
C on native builds with the dummy interface enabled, covering both modes,
LAN, serial, slots-only, truncated replies, selectors and statuses. The
`session_info_*` CLI snapshots remain the C byte oracle.
Without local readline/OpenSSL headers, add `-Dipmishell=false -Dopenssl=false
-Dinternal-md5=true -Dintf-lanplus=false`.

Session command arguments now use NUL-aware Zig byte equality instead of
libc `strcmp`; the transport-name check is bounded to its 16-byte interface
field. `zig build test-session-strings` compares the dispatch names, first
byte variations, embedded NULs and valid interface names with libc. A
nonterminated interface name is rejected without reading beyond the field.
The existing `session_info_*` C/selected CLI cases preserve request bytes,
messages and statuses.

The selected `user test` password result now uses a checked Zig stdout writer
for success, incorrect password, wrong size, and unknown errors, retaining
the original bytes and return statuses. It pre-flushes C stdout before
writing and checks the Zig write and final flush, logging failures and
returning `-1`. `zig build test-user-password-test-stdout` checks C-format
bytes, mixed buffered C/Zig order, and pre-flush, early/late write and
final-flush errors. The existing `user_test_*` C/selected-Zig CLI goldens
cover success and failure codes.

The selected `user set password` prompt uses bounded Zig decimal formatting
instead of libc `snprintf`. The original 128-byte static buffer remains
zeroed on each call and is reused for `getpass`; `zig build
test-user-password-prompt` compares its entire buffer and pointer lifetime
with the C formatter for every `u8` user ID.

The selected `user priv` and `user set password` success acknowledgements
stream through checked Zig stdout after a libc pre-flush. They preserve the
C wording, user IDs, newline and status, while pre-flush, write and final-flush
failures log the phase and return `-1`. Request failures and the other user
subcommands retain their existing behavior. `zig build test-user-write-ack-stdout`
checks libc byte parity, C/Zig buffered output order and injected I/O failures.
The existing `user_priv_*` and `user_pw_*` original-C and selected-Zig CLI
goldens cover successful and rejected requests and option parsing.

The selected LAN v1.5 Activate Session completion-code path now writes only
the `Activate Session error:` prefix with Zig stderr I/O. It deliberately
has no newline: the immediately following `lprintf` starts with a tab on
the same line. A checked libc `fflush(stderr)` drains earlier buffered C
logging before the Zig write; the Zig write and final flush are checked
before logging resumes. Any I/O failure terminates explicitly, rather than
silently returning the usual `-1`. The completion-code switch, return
status, C ABI, and original C transport remain unchanged.
`zig build test-lan-activate-stderr` compares the prefix with C bytes, checks
early/late writer failures and buffered C-output ordering. The
`lan/activate-error` transport case compares the original C and selected
Zig responses, including the tab-joined error line and exit status. Run
`zig build test-transport -Dipmishell=false -Dopenssl=false
-Dinternal-md5=true -Dintf-lan=true -Dintf-lanplus=true
-Dzig-modules=lanplus,lanplus-crypt,lanplus-crypt-impl --
--filter lan/activate-error` for the C LAN oracle and all-selected Zig
candidate, then include `lan` in `-Dzig-modules` to check the selected LAN
path in the main binary as well.

The three selected `event 1`/`2`/`3` sample announcements use checked Zig
stdout after flushing buffered C output, before SEL rendering and sending
the Platform Event Message. Their C byte shape and ordering are pinned by
the `event_num_*` C/Zig CLI goldens; `zig build test-event-sample-stdout`
compares all three lines with libc formatting and tests pre-flush, early,
late and final-flush failures. Output errors log a diagnostic and return
`-1` without sending the event.

The selected `event <sensorid>` lookup now emits its `Finding sensor
<sensorid>... ` prefix and `not found!`/`ok` line through checked Zig stdout.
It flushes C stdout before each phase and flushes Zig output immediately,
so C SDR lookup output between them and later C state-table/SEL rendering
retain their order. The sensor name is measured through its first NUL, just
like C `%s`. `zig build test-event-sensor-stdout` compares libc bytes for
empty, embedded-NUL, percent, whitespace and arbitrary byte IDs, and
exercises preflush, early/partial writes and final-flush failures in both
phases. On failure it logs the phase and returns `-1` before the lookup
(finding failure) or before state processing (result failure). The
`event_sensor_*`, `event_thresh_*` and `event_digi_*` CLI goldens pin the
C/selected/all-selected byte order, requests and statuses; state-table and
other event output remain in C.

The selected event command now compares command/shortcut names and measures
argument/file-line text with NUL-aware Zig operations. It finds the first `#`
in a file line without libc `strchr`, still truncating that writable line in
place before libc whitespace classification and bounded Zig tokenization.
`zig build test-event-cstrings` compares equality, comment pointer offsets
and lengths with libc across every first byte and embedded NULs. The
`event_` CLI goldens preserve comments, whitespace, requests and failures.

The selected `event file` parser now splits the at-most-1023-byte input line
on ASCII spaces using per-line Zig state instead of libc's global `strtok`
state. It skips repeated spaces and chops reached delimiters in place, but
does not split on tabs; leading/trailing libc whitespace stripping, comments,
seven-byte limit, `str2uchar` conversions, diagnostics and sticky file errors
remain unchanged. `zig build test-event-space-tokens` compares token offsets,
whole-buffer mutations, every byte value and interleaved lines with the
test-only libc `strtok_r` oracle. The `event_file_` C/selected/all-selected
CLI goldens compare outputs, exit statuses and request bytes for whitespace,
invalid and overflow tokens, ignored extra tokens and later valid lines.

Selected `sel time get` and the readback after a successful `sel time set`
stream the original `ipmi_timestamp_numeric()` bytes plus newline through
checked Zig stdout. The C formatter still controls special timestamps,
timezone, locale, and DST; its static string is consumed before another
formatting call. A checked libc stdout pre-flush preserves buffered C/Zig
order, and write/final-flush errors log their phase and return `-1`.
The GET command still ignores BMC/request/length errors for its exit status;
SET still succeeds if its readback has such an error, but neither path
silently ignores a readback *output* failure. `zig build
test-sel-time-stdout` compares C bytes, mixed buffering, exact request
counts/statuses, and injected pre-flush/write/final-flush failures. The
`sl_time_*` and `sel_time_*` original-C/selected-Zig goldens cover the CLI
including fixed timezones and DST; unrelated SEL record output is unchanged.

The selected `sel info` statistics display now streams checked Zig stdout
after a libc pre-flush. It preserves C's version/percent/flags formatting,
trailing spaces, timestamp sentinel handling and immediate consumption of
the C timestamp formatter's static buffer. The main response is printed
before the optional allocation-info request; that result has its own checked
pre-flush, write and final flush. Request validation, optional-response
length behavior, partial stdout on later failures, and return statuses
remain as in C except that output failures now log their phase and return
`-1`. `zig build test-sel-info-stdout` compares libc bytes across response
flags and size boundaries, buffered output order, request statuses and
injected failures. The original-C/selected-Zig `sel_info` and `sl_info_*`
goldens cover the actual dummy interface; SEL record printers are unchanged.

SEL OEM translation tokens (`XX`/`R`) and PPS `interpret` format selection
now reuse the NUL-aware Zig equality used by command dispatch. The 256-byte
`fgets` PPS line buffer uses a bounded NUL search for its existing 255-byte
overlong-line decision, preserving the conditional `fgetc` and parse order.
Dell DIMM numbers (one to three decimal digits) use a three-byte Zig scratch
and explicitly terminate the existing 32-byte DIMM text; the allocator-owned
description and remaining record formatting stay on libc. For spec 2.0 the
optional `incr` is at most `14 << 3` (low nibble `0xf` skips assignment);
the bit index is at most 7, so even C-width `i + incr + 1` cannot exceed
120. The per-node branch formats at most 24. Only the copied digits and
terminator enter `dimm_str`; the existing `tmpdesc` initialization remains,
but that scratch is not read again after the removed `sprintf` calls.
`zig build test-sel-cstrings` compares equality, byte lengths and DIMM
strings to libc, including embedded NULs, every response-byte-derived
DIMM index, numeric boundaries and full-buffer trailing bytes after
successive numbers. The `sl_oemmsg_*`,
`sl_int_*` and `sl_dell*` original-C/selected-Zig CLI cases cover resulting
output, statuses and requests. General record/path formatting, allocation-
sized lengths and PPS `strtol` parsing remain C interop seams.

The SEL `add` file reader now clips `#` comments, trims C-locale whitespace,
copies the diagnostic line including its NUL, and splits tokens on literal
spaces using bounded Zig slices instead of `strchr`/`strlen`/`strcpy`/`strtok`.
Tabs still trim at the edges but never separate byte tokens; only the first
seven tokens enter the existing `str2uchar` converter and entry request.
`fgets` still owns the 1024-byte input buffer; empty/comment lines, malformed
byte diagnostics, `feof`/file-close behavior and BMC rejection statuses are
unchanged. `zig build test-sel-add-strings` compares the entire mutated input
buffer, diagnostic copy and token bytes against libc for
whitespace, comments, embedded NULs and both 1022/1023-byte `fgets` edges.
The `sl_add_*` original-C, SEL-selected and all-selected goldens pin CLI
output, request bytes and exit statuses. This does not change the separate
SEL PPS parser or event description formatter.

The selected `sol payload status` result now uses checked Zig stdout for
both enabled and disabled lines, retaining the C decimal fields and newline.
The C stdout pre-flush preserves buffered output from earlier code; write
or final-flush failures log and return `-1` rather than reporting success.
The C implementation and `sol_payload_status` golden remain the reference.
`zig build test-sol-payload-stdout` compares enabled/disabled boundary values
with libc formatting, checks mixed C/Zig ordering and injects pre-flush,
early, late and final-flush failures. Other SOL output and the interactive
session were unchanged by that payload-status cutover.

The selected `sol info` CSV and human result printer streams through checked
Zig stdout after a checked C stdout pre-flush. Its existing nine parameter
requests, error statuses and diagnostics are unchanged. CSV retains the C
printer's duplicated force-encryption field; human labels, spacing, decimal
scales, lowercase channel hex and final newlines remain byte-identical.
Each `val2str` result is written before the next lookup because unknown values
reuse one C fallback buffer. A write or final-flush error logs and returns
`-1`. `zig build test-sol-info-stdout` compares libc-format boundary values
and tests fallback-buffer reuse, mixed C/Zig output order and pre-flush,
early/late write and final-flush failures. The `sol_info_*` C and selected Zig
goldens additionally check all original request/error paths and distinct
unknown fallbacks in both output formats; only SOL info result printing moved.

The selected SOL interactive *text* output now uses checked Zig streaming
stdout: activation banners, escape help and acknowledgements (`~.`, `~^Z`,
`~^X`, `~B`), and looptest progress/failure lines. It writes the escape
character as one raw byte, preserving C `%c` even for high-bit values and
the original `~^X` acknowledgement's `^Z` spelling. Every message pre-flushes
libc stdout and checks its writes and final flush; failures log the phase
and return `-1` rather than reporting a successful control action. An
activation banner failure deactivates the payload; a mid-session output
failure restores terminal mode and deactivates without falsely reporting
that the BMC closed the session. Non-output request, escape, raw-terminal,
binary SOL payload and wire behavior remains unchanged. The binary payload
callback deliberately retains `fwrite`/`fflush` rather than text formatting.
`zig build test-sol-interactive-stdout` checks libc bytes, C/Zig/binary
output order, escape and looptest statuses, requests and injected failures.
The existing C transport fixtures for `lanplus/sol-pty-*` and
`lanplus/sol-looptest` compare the actual terminal session and wire traffic
in original-C and selected-Zig builds.

LAN+ RMCP pong responses also use that checked pre-flush before Zig stdout.
At verbosity zero they produce no output; at one (or negative verbosity)
they print only the supported/unsupported line, and above one they also print
the ASF/RMCP versions, sequence and unsigned, network-order IANA enterprise
number, retaining the C trailing blank line. Writes and final flushes fail
explicitly; the `-1`/`0`/`1` ping status and the original C oracle are
unchanged. `zig build test-lanplus-pong-stdout` checks exact bytes at
verbosity 0/1/2, both version branches, sequence and enterprise boundaries,
and first/second write failures. The shared value-table golden test checks
ordering around libc-buffered stdout. The `lanplus/pong` transport fixtures
compare original C LAN+ against selected Zig at verbosity 0/1/2, including
earlier buffered C output before the pong details at verbosity 2. Only the
dynamic CLI version, the 16-byte random-number diagnostic and the single
trailing space on stderr's `>>    data    :` diagnostic lines are normalized
there, not stdout or any other stderr lines.
For LAN+ IPMI payloads at verbosity two or higher, the selected transport
writes the stderr `>>    data    :` hex diagnostic through a Zig streaming
writer after checking libc stderr's buffered output. It retains the trailing
space after each byte, the empty-data space, and two terminating newlines.
Write and final-flush failures terminate explicitly; `zig build
test-lanplus-data-stderr` compares all byte values with libc's `%02x` and
checks early and late writer failures. The existing `lanplus/pong-details`
C/Zig transport fixture checks its place among adjacent C logging output.
RAKP 1 now measures the fixed 17-byte username in Zig, preserving the
16-character limit, error diagnostic and framing for NUL-terminated names.
Unlike unbounded C `strlen`, an unterminated username is safely rejected as
17 bytes. The optional hostname guard checks only the first byte, retaining
the null/empty failure path; `test_crypt2` uses the exact eight-byte input
length instead of reading past its nonterminated array as C `strlen` does.
`zig build test-lanplus-lengths` compares terminated and embedded-NUL lengths
with libc, checks the username boundary and unterminated input, and checks
null/empty hostnames. The LAN+ transport fixtures pin valid-input wire parity.
For the complete cipher-17 and auto-cipher suite without local OpenSSL
headers, use `-Dipmishell=false -Dopenssl=true -Dinternal-md5=true
-Dintf-lanplus=true -Dzig-modules=lanplus-crypt,lanplus-crypt-impl` with
`zig build test-transport -- --filter lanplus`: Zig crypto supplies the
algorithms while the feature flag keeps SHA-256 cipher selection enabled.
`-Dopenssl=false` disables SHA-256 and cannot match three existing fixtures.
Without local OpenSSL headers, run the pong unit with
`-Dipmishell=false -Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false`
(the unit runs independently of the transport). The transport comparison
instead enables LAN+ with Zig crypto:
`zig build test-transport -Dipmishell=false -Dopenssl=false
-Dinternal-md5=true -Dintf-lanplus=true
-Dzig-modules=lanplus,lanplus-crypt,lanplus-crypt-impl -- --filter lanplus/pong`.

The three selected LAN+ open-session, RAKP 2 and RAKP 4 verbose dumps use
`util/stdout.zig` to pre-flush buffered C stdout, stream typed Zig output and
fail explicitly on write or final flush errors. The C ABI, packet layout,
verbosity threshold, status-failure behavior, lookup tables, SHA256 feature
gate, and original C source remain unchanged. The legacy spelling, spacing
and auth-code newline quirks are byte-preserved. With LAN+ enabled,
`zig build test-lanplus-dump-stdout` compares the original C caller to the
selected Zig ABI under both SHA256 feature options, including verbosity 0/2,
success/failure, all auth arms, mixed C/Zig ordering and writer failures.
Without OpenSSL headers, use `-Dipmishell=false -Dopenssl=false
-Dinternal-md5=true -Dintf-lanplus=true
-Dzig-modules=lanplus-crypt,lanplus-crypt-impl`; the transport fixture gate
can additionally select `lanplus,lanplus-dump` to exercise packet parity.

On musl, `src/zig/util/helper.zig` uses Zig's Linux `statx` for no-follow path
and opened-file checks because the translated `struct stat` is opaque. Its
verified-file path requires Linux 4.11 or newer; unsupported kernels or
missing required file type, mode, link count, inode or owner metadata fail
closed. Only `ENOENT` allows creation of a new file. The event daemon uses
`statx` to check whether its PID path exists (including a dangling symlink),
then uses exclusive creation, so an unsupported `statx` cannot overwrite an
existing PID file. glibc still uses `lstat`/`fstat`; no C shim was added.
The selected event daemon retains `open(O_EXCL, 0644)` for PID ownership,
but writes the decimal PID and newline with a checked Zig streaming writer
instead of `fdopen`/`fprintf`/`fclose`. A write, flush or close failure removes
the new file and reports the existing PID creation error; the daemon process
fixture checks exact bytes, permissions and cleanup after both stop signals.
The default C daemon remains the oracle.

The ISOL, LAN, LAN+ and OpenIPMI ports share a Zig-only `fd_set` helper. It
accepts a translated libc type only when its size, alignment and single
long-word-array layout match `FD_SETSIZE`; no private glibc field name or
production C shim is needed. `zig build test-fdset` checks the word and
capacity boundaries against libc's `FD_*` macros in a test-only C oracle;
`test-fdset-compile` checks those ABI assertions on cross targets. OpenIPMI
also passes `ioctl` requests in the request type declared by the target libc,
preserving the 32-bit request bits on musl.

The LAN and LAN+ Zig transports use `util/log.zig`'s typed `print` for
literal C `printf` diagnostics. Both transports and the selected logger are
imported into the same `exports.zig` archive, so they share one logger state;
when `log` is not selected, `print` forwards to the C `lprintf` instead.
The transport fixture `lanplus/open-session-auth-mismatch` pins a warning's
`%02x` formatting against the C logger (including zero padding). Other
remaining variadic C callers still use the logging trampoline.

CI cross-builds the all-selected `ipmitool` and `ipmievd` binaries in
`ReleaseSafe` for the opposite runner architecture with musl and verifies
that neither executable has an ELF interpreter or `NEEDED` library. The
reduced-feature gate disables the shell and OpenSSL/LAN+; a second gate
retains the default shell, LAN+ and crypto features. The selected Zig
implementations need neither readline nor OpenSSL libraries, but both
configurations still link musl libc. The fully selected tool omits the
logging C shim, while selections combining the Zig logger with C modules
retain it. The all-selected build rejects any remaining C source for either
tool, and `test-no-log-varargs` checks the two production archives for C
objects as well as the C logger ABI. CI also runs the complete all-selected
test suite on both native architectures, including the daemon's shared logger
state. This is not a libc-free build or a
pure-Zig release.

`src/zig/cli/main.zig` is linked through `exports.zig` into the shared Zig
archive, unlike the separate `cli/tool.zig` executable root. Its diagnostics
use the typed logger in that archive, sharing its state when `log` is selected
and calling C `lprintf` when it is not. The `cli_transit_hex_channel` golden
case pins the C stderr formatting for `%#x` addresses and channels. Do not
import the logger into `cli/tool.zig` without sharing its state first.

The archive-selected `raw`, `channel`, `user` and `event` command ports also
use `util/log.zig`'s typed logger. When `log` is selected they share its state
and preserve libc printf formatting with their original argument widths;
otherwise the wrapper calls C `lprintf`. The default C-oracle fixtures
`raw_log_ccode_hex` and `chan_log_priv_bad_numeric` pin hexadecimal completion
codes and `%hhu` privilege bounds without changing existing snapshots.

The selected channel cipher listing now uses bounded Zig formatting for its
six-digit-minimum lowercase OEM IANA value and Zig NUL-aware equality for the
`ipmi` payload selector. `zig build test-channel-strings` compares those
decisions and bytes against libc, including wide 32-bit values, all first
bytes, embedded NULs and a too-small destination. The `chan_` CLI goldens
preserve cipher requests, output and exit statuses for C and selected Zig.

`lanplus-strings` exports the exact RAKP status and privilege lookup arrays
used by both C and Zig LAN+ transports. The C tables remain the default oracle;
`zig build test-lanplus-strings` checks every value, string and terminator
against both implementations, including the `struct valstr` ABI.

`lanp` replaces `lib/ipmi_lanp.c` and exports both `ipmi_lanp_main` and
`find_lan_channel`. The latter is also used by the separate IPv6 `lan6` command
(`lib/ipmi_lanp6.c`), so `lanp` and `lanp6` can be selected independently.
The C/Zig parity fixtures for LAN print, alert destinations, stats and writes
are in `tests/cases/57-lanp.cases`; run them with
`tests/run.sh --binary zig-out/bin/ipmitool --filter lanp_`.
`zig build test-lanp` runs the focused Zig parameter and short-reply tests
without depending on unrelated crypto vector fixtures.

`-Dzig-modules=dcmi` replaces `lib/ipmi_dcmi.c` with
`src/zig/cmd/dcmi.zig` and `src/zig/cmd/nm.zig`. It exports both top-level
commands (`dcmi` and `nm`), their C-callable wire helpers, and their public
value tables. `tests/cases/57-dcmi.cases` and `58-nm.cases` record C CLI output
and exact request bytes, including multi-chunk strings, configuration, sensors,
power, thermal policy and Node Manager operations. The Zig parsers check
response lengths and bounded counts before decoding; malformed successful
replies that the C code would read past are rejected rather than silently
consuming stale transport-buffer data.

The selected DCMI command now renders unknown `u16` labels into bounded Zig
storage and matches case-sensitive command names with NUL-aware Zig equality.
`zig build test-dcmi-strings` compares lowercase hexadecimal bytes and
command decisions with libc at digit-width boundaries, for every first byte
and embedded NULs; the `dcmi_` CLI goldens preserve output and requests. The
static label buffer still lasts only until the next unknown lookup.

DCMI and Node Manager now share the bounded lowercase hexadecimal unknown
label formatter. The selected Node Manager also compares its top-level
`help` argument with NUL-aware Zig equality; locale-sensitive option
lookups still use libc `strcasecmp`. `zig build test-nm-strings` checks
every unsigned-byte label and first-byte help comparison against libc.
The `nm_` C/selected/all-selected CLI goldens preserve resulting requests
and output; each module keeps its own static label buffer.

Mechanics, all in `build.zig`:

1. `zig_modules` maps each name to the `.c` it replaces and to its Zig
   implementation.
2. `parseZigModules` splits the option and exits with the list of valid names
   when it sees an unknown one.
3. `addSources` skips any `.c` a selected module replaces, so there is never a
   duplicate symbol; the swap is a substitution, not an override. When all
   modules are selected, a generated Zig-only archive member keeps the core
   archive linkable even if no C core translation units remain.
4. When at least one module is selected, `src/zig/exports.zig` is compiled into
   `libipmitool_zig.a` and linked after `libipmitool_core.a`.
   For `cli`, `src/zig/cli/tool.zig` is also the `ipmitool` executable root;
   the Zig archive exports `ipmi_main`, `ipmi_cmd_run`, and `ipmi_cmd_print` for
   the still-C `ipmievd` and `ipmishell` callers.
5. With no selection the Zig library is not built or linked at all, so the
   default build is bit-for-bit the pre-existing all-C build.

Selecting `-Dzig-modules=fru` now replaces `lib/ipmi_fru.c` in its entirety:
print/list with SDR discovery and PICMG records, read/write, internaluse,
Kontron get, EKey upgrade, field edits and OEM edits. The `fru_legacy.c` shim
has been removed. External consumers such as Kontron OEM commands, SEL FRU
printing and Ekanalyzer link against the exported FRU helper ABIs in Zig.
The Zig OEM editor intentionally fixes the original C code's zeroed FRU size
before multirecord reads; the isolated `tests/zig-fru` fixtures exercise
successful edits that the C oracle cannot perform.

The selected FRU module now uses Zig C-string lengths for file paths and
Kontron version fields and bounded Zig formatting for multirecord type names.
`zig build test-fru-strings` checks path boundaries, embedded NULs and every
`u8` record type against libc; the original C and selected-Zig `fru_*` CLI
goldens preserve output, requests and statuses. The 32-byte name buffer
still belongs to the caller and is valid only until its next write.

### Offline eKey analyzer

`-Dzig-modules=ekanalyzer` replaces only `lib/ipmi_ekanalyzer.c`.
`frushow`, `print`, and `summary` read FRU files directly; they do not send
IPMI requests. The module keeps its public C symbols (entry point, value
tables, and constants), preserves the historical output for valid records,
and checks all offsets and descriptor counts before using them. Like the C
analyzer, it reports the stored FRU and multirecord checksum bytes without
rejecting corrupt checksums; the C-oracle CRC snapshots document this
compatibility decision.

The decoder uses the FRU on-disk format itself and calls only the stable C
ABI for `get_fru_area_str()`, `ipmi_timestamp_numeric()`, `val2str()`, and
logging/stdio. It does not import the FRU or PICMG command implementations;
their independent Zig migrations can therefore replace their C translation
units without changing this module. The original C analyzer stays available
in the default build as the oracle until the final C removal.

Run `zig build test-ekanalyzer` for isolated malformed-descriptor bounds
tests, or `zig build test-golden -Dzig-modules=ekanalyzer -- --filter ek_`
for C-oracle output, exit-status, and CLI-wire parity (including OEM GUID
matching and PICMG multirecord rendering).

The PEF replacement preserves all 18 externally visible symbols, including
the public flag/field printers and configuration getters. Its filter/policy
table walks and LAN/serial destination decoders are covered by
`tests/cases/57-pef.cases`; those snapshots were recorded against the C
implementation before the swap. The Zig decoder rejects truncated BMC
responses rather than reading bytes beyond the reply, and its table iterator
terminates when a BMC advertises 255 filter entries (the C `uint8_t` counter
would wrap).
Run `zig build test-pef-unit` for the focused PEF unit tests without
running unrelated crypto vector fixtures.
PEF command matching now uses NUL-aware, case-sensitive Zig equality; fixed
trigger labels, trigger prefix/suffix text and IPv4 addresses use Zig copies
and bounded formatting. `zig build test-pef-strings` compares these bytes
against libc, including embedded NULs, hex and decimal digit boundaries,
multi-bit trigger masks and the existing 128-byte Zig trigger clamp (C would
overflow that buffer for some masks). The `pef_` CLI goldens pin command case
handling, trigger text and LAN address output against the C oracle.
Filter and policy enable/disable success announcements now use checked Zig
streaming stdout: after the original configuration requests succeed, they
pre-flush buffered C stdout, write the exact C message, and check the final
Zig flush. Pre-flush, write and final-flush failures log the phase and return
`-1`; BMC and validation failures retain their original status and emit no
announcement. `zig build test-pef-status-stdout` checks libc byte parity
across ID boundaries and both states, buffered C/Zig ordering, and injected
output failures. The `pef_status_stdout_*` original-C CLI goldens cover the
last valid filter and policy IDs, including exit statuses and request bytes.

The PEF, firewall and DCMI command ports now use the archive's typed logger
for their diagnostics; with the C logger selected, calls still use its
variadic ABI. `pef_log_status_hex` and `fw_log_unsupported_hex` pin the
original hexadecimal diagnostics against the default C oracle.
The firewall `info` command's selected-pair and all-pairs command-mask
matrices now use checked Zig stdout. Its inverted support mask and normal
configurable/enabled masks retain C's lower-case hex, trailing space after
each four-byte group (including the last), and LUN/NetFn prefixes. Buffered
C stdout is flushed before the first Zig row, not on empty or unsupported
results; Zig write/final-flush failures return `-1`, while the existing
unsupported-pair diagnostic still returns `0`. Detailed command/subfunction
rows and reset/enable/disable output remain on their original paths.

`exports.zig` gates each port on a build option, so an unselected module is
never analysed and exports nothing:

```zig
comptime {
    if (selected("oem")) {
        _ = @import("cmd/oem.zig");
    }
}
```

### Retained command-support modules

`-Dzig-modules=cfgp,session,hpm2` replaces three independent C translation
units, each with all its externally visible symbols:

* `cfgp` (`lib/ipmi_cfgp.c`) is used by the retained `lan6` command in
  `lib/ipmi_lanp6.c`. Its nine C ABI entry points accept borrowed descriptor,
  selector and callback pointers. `ipmi_cfgp_parse_data` and `ipmi_cfgp_get`
  allocate list nodes with libc `malloc`; callers own the context and call
  `ipmi_cfgp_uninit` to free its nodes, including after a partial GET. Null,
  invalid and allocation failures return `-1`; the handler's nonzero GET
  result is mapped to `-1` at the public entry point.
* `session` (`lib/ipmi_session.c`) supplies `ipmi_session_main` and the
  externally linked `ipmi_get_session_info`. Both only *query* the BMC; they
  do not create or destroy a transport session. Session establishment,
  keepalive and cleanup live in the retained LAN/LAN+ transport plugins and
  `src/plugins/ipmi_intf.c`, so none is dropped by this substitution. Requests
  and response decoding need no dynamic memory.
* `hpm2` (`lib/hpm2.c`) exports both capability queries and
  `hpm2_detect_max_payload_size`; `src/plugins/{lan,lanplus}` and their Zig
  alternatives call the latter during transport setup. Buffers are
  stack-owned and failures leave the capability outputs zeroed or partially
  populated just as the C implementation does.

The C behavior was characterized before the swap. Run
`zig build test-command-support` to execute `tests/command_support.c` both
against the C objects and against the three Zig replacements. The golden
cases `session_info_*` and `lan6_*` additionally compare CLI output, status
and request bytes against C snapshots (including truncated responses,
selectors and errors). A standalone selection still builds with
`zig build -Dzig-modules=cfgp,session,hpm2`.

## The ABI parity harness

Each header port is an `extern struct` mirror plus a `comptime` block that
proves it matches C. Because both sides are evaluated for the *target*, the
assertions stay correct when cross compiling, on big endian targets and under
either `HAVE_PRAGMA_PACK` setting. Nothing has to run.

### Faithfully translated types: `assertLayout`

```zig
comptime {
    abi.assertLayout(Intf, c.struct_ipmi_intf);
}
```

`assertLayout` checks `@sizeOf` and `@alignOf` of the struct, that the field
count matches, and for every field that the name, the offset, the size and the
alignment agree. It needs no maintenance: adding a field to the C header fails
the build until the mirror gets it too.

Nested anonymous structs and unions are asserted separately by pulling the C
type out with `@FieldType`:

```zig
abi.assertLayout(Response.Session, @FieldType(c.struct_ipmi_rs, "session"));
```

### Types `translate-c` cannot represent: `assertOpaqueLayout`

`translate-c` demotes any struct containing a bitfield to `opaque {}`, so
`@sizeOf` and `@offsetOf` are unavailable — this hits `struct ipmi_rq`,
`struct ipmi_rq_entry`, and several `ipmi_sdr.h` and `ipmi_sel.h` records.

`src/zig/abi_layout.h` restates their layout as plain `enum` constants, which
`translate-c` does handle:

```c
ABI_SIZEOF_ipmi_rq = sizeof(struct ipmi_rq),
ABI_OFFSETOF_ipmi_rq__msg__cmd = offsetof(struct ipmi_rq, msg.cmd),
```

and the mirror compares against those:

```zig
abi.assertOpaqueLayout(Request, .{
    .size = c.ABI_SIZEOF_ipmi_rq,
    .alignment = c.ABI_ALIGNOF_ipmi_rq,
    .fields = &.{
        .{ .name = "msg.cmd", .offset = c.ABI_OFFSETOF_ipmi_rq__msg__cmd },
    },
});
```

The numbers still come from the C compiler, so this is as target-accurate as
`assertLayout`; it just costs one line of C per field.

### Bitfields

C allocates bitfields from the least significant bit on little endian targets
and from the most significant bit on big endian ones, while a Zig `packed
struct` always starts at the least significant bit of its backing integer. Port
a bitfield group as a `packed struct(uN)` whose declaration order follows the
target:

```zig
pub const NetFnLun = switch (builtin.target.cpu.arch.endian()) {
    .little => packed struct(u8) { netfn: u6, lun: u2 },
    .big => packed struct(u8) { lun: u2, netfn: u6 },
};
```

Bitfield members have no address, so assert the offset of the field that follows
them instead.

### `#pragma pack` is silently lost

`ipmitool` packs its wire structs with `#pragma pack(push, 1)` whenever
`HAVE_PRAGMA_PACK` is defined — which it is on every platform the build
supports, so `ATTRIBUTE_PACKING` expands to nothing and the pragma does all the
work. `translate-c` **ignores the pragma**: it emits an ordinary `extern
struct` with natural alignment, and the resulting Zig type compiles cleanly
while pointing at the wrong bytes.

`struct sdr_record_list` is the worked example. C makes it 29 bytes with
`record` at offset 21; `c.struct_sdr_record_list` is 32 bytes with `record` at
offset 24, so `sdr.record.common` reads three bytes into the pointer and yields
garbage. Nothing warns, and the symptom is a SIGSEGV a long way from the cause.

So: **a type is only safe to use straight from `ipmi_c` if it is not inside a
`#pragma pack` region.** For anything between a `push` and a `pop`, write a
mirror with `align(1)` fields and pin it with `assertOpaqueLayout`, exactly as
if `translate-c` had demoted it to `opaque {}` — the mirror in
`src/zig/cmd/event.zig` is the pattern to copy. `grep -n 'pragma pack'
include/ipmitool/*.h` lists the affected regions.

### Adding assertions for another header

1. Write the mirror as an `extern struct` in `core/`, `intf/` or `util/`, with
   the C field names, in the C order.
2. Add `#include <ipmitool/your_header.h>` to `src/zig/ipmi_c.h`.
3. Add `comptime { abi.assertLayout(Mirror, c.struct_your_type); }`.
4. If the build reports the C type as `opaque`, add `ABI_*` constants for it to
   `src/zig/abi_layout.h` and use `abi.assertOpaqueLayout` instead.
5. Reference the new module from `src/zig/root.zig` so `zig build test`
   compiles it.

Headers with ABI assertions today: `ipmi.h`, `ipmi_intf.h`, `ipmi_oem.h`, and
the lookup-table types from `helper.h`. Everything else is still to do; the
recipe above is the whole cost of adding one.

## Recipe: porting one C module

The steps for `lib/ipmi_<name>.c`, in order. One PR per module.

1. **Branch.** `port/<name>`.
2. **Read the C.** Note every exported symbol (`nm` the object, or grep the
   header) and every symbol it calls. The exported set is the contract; the
   called set decides what must exist in `ipmi_c`.
3. **Mirror the types it needs.** Anything from `include/ipmitool/*.h` that is
   not mirrored yet goes into `core/`, `intf/` or `util/` with the ABI
   assertions from the previous section. Do this first — the assertions are what
   make the rest safe.
4. **Write `src/zig/cmd/<name>.zig`.** Keep the C control flow. Reach remaining C
   through `@import("ipmi_c")`, never through `extern fn`. End the file with the
   `comptime` block that pairs `abi.assertCallSignature` with `@export` for every
   symbol the C translation unit exported.
5. **Register the module.** One entry in `zig_modules` in `build.zig`, one
   guarded `@import` in `src/zig/exports.zig`.
6. **Verify.** See the checklist below.
7. **Open the PR** with the parity evidence in the body.

Order the work so that a module is ported only after everything it *exports* to
is still C, i.e. leaves first. `lib/ipmi_oem.c` was chosen as the first port
because it exports three functions, has no state beyond one static table, and
its entire observable behaviour is reachable from `ipmitool -o list`.

## Review checklist for a port PR

* [ ] Every symbol the `.c` exported is exported by the Zig module, with
      `abi.assertCallSignature` against the `ipmi_c` prototype.
* [ ] No symbol the `.c` did *not* export is exported (C `static` functions stay
      private in Zig).
* [ ] The `.c` is removed from the build by the `zig_modules` entry, not by
      deleting it — the C stays in the tree until the whole migration lands, so
      the swap can be flipped back for bisecting.
* [ ] No `.c` or `.h` outside `src/zig/` is modified. If one is, the PR body
      says why.
* [ ] Calls into remaining C go through `@import("ipmi_c")`.
* [ ] Every `@ptrCast` between a mirror and a bridge type is backed by an
      `assertLayout`/`assertOpaqueLayout` on that type.
* [ ] Types are `PascalCase`, functions `camelCase`, files `snake_case.zig`;
      struct fields keep their C names.
* [ ] `zig build` (default) still matches the oracle for `-h` and `-V`.
* [ ] `zig build -Dzig-modules=<name>` links and produces identical output to
      the default build for every code path the module touches.
* [ ] `zig build test` passes with and without the flag.
* [ ] `zig fmt --check` passes over the added files.
* [ ] The golden suite covers at least one command that exercises the module.

## Verifying a port

```bash
# default build: still all C, still matches the oracle
zig build -p zig-out/c
diff <(tail -n +2 <oracle>/ipmitool-h.txt) <(./zig-out/c/bin/ipmitool -h 2>&1 | tail -n +2)

# with the module swapped in
zig build -Dzig-modules=<name> -p zig-out/zig

# differential check of the affected code paths
diff <(./zig-out/c/bin/ipmitool <args> 2>&1) <(./zig-out/zig/bin/ipmitool <args> 2>&1)

# the same check for the whole CLI surface, including the IPMI request bytes
./tests/run.sh --binary ./zig-out/c/bin/ipmitool --candidate ./zig-out/zig/bin/ipmitool

# ABI assertions, smoke tests and the golden suite, both ways
zig build test
zig build test -Dzig-modules=<name>

zig fmt --check build.zig src/zig/
```

`zig build test` runs the golden CLI suite (issue #4,
[golden-harness.md](golden-harness.md)) twice: once against the default all-C
binary and once against a binary with every registered module swapped to Zig.
That is the differential check that used to be spelled out here as an inline
`-o list` assertion. When porting a module, add a golden case that exercises it
if the existing cases do not already reach it.

The golden suite speaks only to the `dummy` interface, so it cannot see
checksums, session state or packet assembly (issue #26). `zig build test` also
runs the transport fixture suite
([transport-fixtures.md](transport-fixtures.md)), which drives the binary
against a model BMC over loopback UDP and byte-compares every datagram. Any
port that touches `lan`, `lanplus`, `ipmi_intf` or `ipmi_csum` must keep
`tests/transport/fixtures/` unchanged.

To confirm the substitution actually happened rather than the C silently winning
the link:

```bash
nm zig-out/zig/bin/ipmitool | grep ' T ipmi_<name>_'
```

The C file's `static` helpers must be absent and the public symbols present.
