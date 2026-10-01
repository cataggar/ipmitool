# Pure timezone prerequisite (#228)

`src/zig/util/timezone.zig` decodes bounded TZif v1/v2/v3 files and POSIX TZ
specifications without C imports, libc or process-global timezone state.
This is a prerequisite, **not** the `util/time.zig` adapter cutover or completion
of #228. That adapter remains unchanged; calendar/locale formatting is separate.

## Offset API and ownership

```zig
var zone = try timezone.Zone.fromTZif(allocator, file_bytes);
defer zone.deinit();
const local = zone.offsetAt(posix_seconds);
// local.utc_offset_seconds: i32, seconds east of UTC
// local.is_dst: bool (also meaningful for negative/half-hour DST)
// local.abbreviation: []const u8, borrowed until zone.deinit()
```

`offsetAt` accepts every signed `i64` POSIX instant and performs a binary
transition search, or evaluates the future POSIX rule tail. Input timestamps
are already absolute instants; callers must not apply offsets to BMC-relative
`S+` values or reinterpret a `time_t` as an unconverted local time (#23).
Calendar callers add the returned offset with overflow-aware/wider arithmetic.
Abbreviations are opaque byte strings, including historical names; they are
not locale-dependent and are not inferred from the offset.

`Zone.fromTZif(allocator, bytes)` and `Zone.fromPosix(allocator, spec)` copy their
inputs. `Zone.loadFile(allocator, io, dir, path)` uses Zig 0.16 `std.Io`, reads at
most 1 MiB, owns the read buffer, and propagates open/read/limit/parse/OOM errors.
`deinit` frees all owned bytes/arrays; do not shallow-copy/deinitialize the same
Zone twice. `timezone.Posix.parse(bytes, default_rules)` is a separate
allocation-free parser whose abbreviation slices borrow its input.

Ruleless DST (`EST5EDT`) has installation-dependent rules. It returns
`MissingDstRules`, not an invented US rule or UTC fallback.
`Zone.fromPosixWithRules(allocator, spec, ?Posix.Rules)` allows an adapter to
inject validated explicit rules. Loading/adapting the system's `posixrules`
history is still an integration responsibility, not a silent parser default.

## Bounds, TZif and libc compatibility

Every header, section length, signed 32/64-bit transition, type index,
abbreviation index/NUL boundary and boolean indicator is checked before use.
Counts are bounded to 32,768 transitions, 256 types, 65,536 abbreviation bytes
and 1,024 leap records; inputs are capped at 1 MiB and POSIX text at 4,096 bytes.
Unsupported versions (including v4), truncated sections, non-increasing
transitions, invalid leap corrections/indicators and malformed/inconsistent
footers return explicit errors. The obsolete 32-bit compatibility block of
v2/v3 is bounded/skipped, not mistaken for the authoritative 64-bit block.

Leap-aware TZif transition values are normalized once by their cumulative
signed correction onto the POSIX timestamp scale. Positive and negative leap
tables are validated; this offset API does not synthesize `tm_sec == 60` or
format leap seconds. Empty future tails retain the last explicit type.
Nonempty tails must agree with the final transition's offset/DST/abbreviation.

Characterized glibc selection is intentional, not an accidental UTC assumption:
before the first transition, choose the first non-DST type (type zero only if
all types are DST); a TZif table with no transitions uses that type even when a
footer exists. POSIX-only zones use their specification for all instants.
POSIX rule evaluation follows glibc's UTC calendar-year selection and its
pre-1970 January-1 epoch anchoring, including the resulting historical and
out-of-day/year-boundary behavior. Do not silently replace these rules with
a more intuitive extrapolation during the formatter migration.

POSIX offsets use the reversed POSIX sign convention (`XYZ5` is UTC-05:00).
Alphabetic/quoted names, explicit/default DST offsets, northern/southern
hemispheres, last-week `Mmonth.week.weekday`, leap-skipping `Jn`, leap-counting
zero-based `n`, signed/out-of-day clocks through 167:59:59, and `w`, `s`,
`u`/`g`/`z` clock suffixes are supported. Suffix semantics are directly tested;
they are not inferred from libc's permissive treatment of unsupported text.

## Independent evidence and focused gates

`src/zig/util/testdata/timezone-libc.json` freezes installed tzdata **2026c**
TZif bytes (New York, Lord Howe, Dublin, UTC) with per-file SHA256 hashes and
independent **glibc 2.43** observations. Independently struct-packed vectors
characterize pre-first/all-DST/empty-table selection and positive/negative leap
records. POSIX samples cover fixed/quarter-hour offsets, the #23 spring gap and
autumn fold, negative/half-hour DST, leap-year rules, UTC-year boundaries, and a
daily year-2100 future sweep plus exact transition endpoints. The captured
tzdata content is public-domain IANA data, not generated product data.
There are 7,325 frozen observations; the whole JSON SHA256 is
`335373393fac9ec4ed4b35ee326c4c1d248e36b26c280b02244ca9f6c2890c06`.
Both the pure tests and optional replay verify `timezone-libc.SHA256SUMS`.

Optional characterization: `python3 -B tools/gen_timezone_fixtures.py --check`.
It reconstructs the **frozen bytes**, not current system zoneinfo, in the owned
`build/timezone-characterization` directory and replays Python's libc-backed
`localtime`. Leap-aware observations translate POSIX input to libc's leap-aware
scale before comparing the offset/DST/name; calendar leap seconds are outside
this helper. A changed libc behavior fails explicitly. Only explicit
`--capture` replaces the baseline using installed tzdata; such a replacement
does not update the separately recorded digest, which requires review.
No tracked C helper exists, and neither Python, host zoneinfo nor libc is a
default test dependency.

```sh
zig build test-timezone -Dzig-modules=all \
  -Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false -Dipmishell=false
zig build test-timezone-compile -Dtarget=x86_64-linux-musl \
  -Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false -Dipmishell=false
```

The test module explicitly sets `link_libc = false`. Tests also exercise
every-byte mutations/truncation, resource budgets, signed timestamp extremes,
footer boundaries, ownership, observable file errors and every allocation
failure. `test-timezone` belongs to the aggregate test step.

Remaining integration: `TZ`/`TZDIR`/`/etc/localtime` resolution, caching and
reload policy, default-rule-file adaptation, local calendar input's gap/fold
policy, and locale-sensitive formatting/adapter error reporting. None is
silently replaced with UTC or a production `c.localtime` fallback here.
