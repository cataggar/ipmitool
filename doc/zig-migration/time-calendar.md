# Gregorian calendar prerequisite (#228)

`src/zig/util/time_calendar.zig` is an allocation-free, header-free, no-libc
Gregorian calendar and **explicit C-locale** formatter. It is a prerequisite,
not completion of #228 or the removal of the time bridge. It does not discover
the process locale, decode TZif/POSIX TZ, resolve DST gaps/folds, parse dates,
or implement leap seconds.

## Integration API

| API | Contract |
| --- | --- |
| `Civil` | `year: i64`; one-based `month/day: u8`; `hour/minute/second: u8`, default zero |
| `fromEpoch(i64) Civil` | Every signed 64-bit POSIX epoch converts, including negative seconds and astronomical years zero/before zero |
| `toEpoch(Civil) !i64` | Strict inverse; `InvalidDate` or `EpochOutOfRange`, never normalization or saturation |
| `Civil.dayOfYear() !u16` | Zero-based, like `tm_yday` |
| `Civil.epochDay() !i128` | Checked day relative to 1970-01-01; validates the full civil time but ignores its clock when counting days |
| `Civil.weekday() !u3` | Sunday=0, like `tm_wday` |
| `Civil.tmYear() !i32` | Checked `year - 1900`; `YearOutOfRange` outside libc's signed 32-bit `tm_year` |
| `write(*std.Io.Writer, format, Civil, FormatOptions) !void` | Streams without NUL or implicit flush; propagates `WriteFailed` and validation errors |
| `formatZ(buffer, format, Civil, FormatOptions) !usize` | Count excluding NUL; zero if there is no room for the complete text plus NUL |

The calendar uses floor division for negative epochs and exact 400-year
Gregorian eras (146097 days). The day count before astronomical year `y` is
`365*y + floor((y+3)/4) - floor((y+99)/100) + floor((y+399)/400)`.
1970-01-01 is day 719528 relative to year zero. Inverse arithmetic uses `i128`
before checking the `i64` range. Days always have 86400 seconds.
`toEpoch` and `Civil.weekday` share `Civil.epochDay`. Timezone rule calculations
use this wide day helper, not `toEpoch`, because January/rule boundaries can
lie outside the signed epoch range even when the queried instant fits `i64`.
The day helper also accepts every valid civil date with an `i64` year.

`FormatOptions` contains `zone: Zone{abbreviation: []const u8,
offset_seconds: i32 = 0}` and `flavor: enum{gnu, musl}`. The default is the
GNU C-locale profile and an explicitly injected `"GMT"`/zero-offset zone.
The timezone adapter must obtain an offset/abbreviation, check `epoch + offset`
for overflow, call `fromEpoch` on that wall-clock scalar, and pass the zone to
the formatter. **Formatting does not apply the offset again.** Abbreviations
must not contain NUL; empty abbreviations are allowed. No timezone state is
read or modified by this helper.

Calendar conversion supports the full `i64` epoch range. Formatting additionally
checks `tmYear()` even for a literal-only format, rather than treating an
impossible libc calendar conversion as success. This check and the full-width
calendar year are separate, so a timezone adapter can explicitly implement its
own range/error policy.

## Format inventory and C-locale scope

These are the actual patterns owned by `util/time.zig`:

| Pattern | Existing owner / native integration |
| --- | --- |
| `S+%H:%M:%S` | Relative `ipmi_asctime_r`; general libc adapter retained |
| `S+%yy %jd %H:%M:%S` | Long-relative `ipmi_asctime_r`; libc adapter retained |
| `S+ %H:%M:%S` | Short-relative string/numeric accessors; now native |
| `S+ %y years %j days %H:%M:%S` | Long-relative string accessor; now native |
| `S+ %y/%j %H:%M:%S` | Long-relative numeric accessor; now native |
| `S+ %y/%j` | Relative date accessor; now native |
| `%c %Z` | Absolute asctime/string accessors; locale/TZ adapter pending |
| `%x %X %Z` | Absolute numeric accessor; locale/TZ adapter pending |
| `%x` | Absolute date accessor; locale adapter pending |
| `%X %Z` | Time accessor, including relative stamps; locale adapter pending |

The utility tests also use `%Y` and `%Y-%m-%d %H:%M:%S`. Callers in SEL, SDR,
FRU, MC, PEF, DCMI, Node Manager, Dell OEM and EKey analyzer use the above
accessors, not additional formatting patterns. The SEL setter parses `%x %X`
with locale-sensitive `strptime`; it is **not** migrated by this formatter.
The exported `ipmi_strftime`/`ipmi_timestamp_fmt` ABI also permits external
formats beyond this inventory.

Supported conversions are `%%`, `%a/%A`, `%b/%B`, `%c`, `%d/%e`, `%H`, `%j`,
`%m`, `%M`, `%S`, `%x/%X`, `%y/%Y`, `%Z/%z`, `%w/%u`, `%F/%T`, `%n/%t`.
In the C locale, `%c` expands to `%a %b %e %H:%M:%S %Y`, `%x` to
`%m/%d/%y`, and `%X` to `%H:%M:%S`. English weekday/month names and ASCII
digits are intentional. Numeric widths are **minimums**, never truncation:
two for day/month/clock/two-digit year, three for day-of-year; `%e` uses spaces.

GNU and musl are explicit profiles because their C locales differ:

| Case | GNU / glibc baseline | Zig 0.16 bundled musl baseline |
| --- | --- | --- |
| `%Y`, year 1 | `1` | `0001` |
| `%Y`, year -1 | `-1` | `-001` |
| `%y`, year -1 | `99` | `01` |
| `%Y`, year 10000 | `10000` | `+10000` |
| `gmtime_r` `%Z` | `GMT` | `UTC` |
| Local `TZ=UTC0` `%Z` | `UTC` | `UTC` |
| `%Y`, calendar year 2147485547 (`tm_year=INT_MAX`) | `-2147481749` | `+2147485547` |

The last GNU result is the observed signed-32-bit displayed-year wrap inside
glibc's `strftime`, **not** a calendar arithmetic wrap. The GNU compatibility
profile deliberately reproduces it; `Civil.year` and epoch round trips remain
correct. The minimum valid `tm_year` similarly has distinct `%y` remainders:
GNU `52`, musl `48`. Frozen native fixtures and direct libc differential tests
cover both endpoints. Zone spelling is always injected, not inferred from the
flavor: a future adapter must distinguish UTC/gmtime from configured local UTC.

Width/flag syntax, `%E/%O` modifiers, unsupported directives, trailing `%`,
embedded format NUL and zone NUL return explicit errors. This subset must not
silently replace an arbitrary `strftime` call or any non-C locale.

## Buffer and writer semantics

`formatZ` is not `snprintf`: insufficient capacity returns zero, not the
required length. It counts before writing, reserves space for NUL, and leaves
the entire destination untouched on insufficient capacity. C `strftime`
specifies the failed-buffer contents as indeterminate; existing glibc and
musl can write different partial prefixes, so those prefixes are not a
portable ABI promise. Native tests assert the deterministic untouched-buffer
policy, while differential tests compare exact return values and all
successful bytes including NUL at every capacity boundary.

An empty format returns zero both on success and failure; when capacity is at
least one, successful empty formatting writes NUL. Invalid dates/formats/zones
return errors before touching a destination. The streaming `write` API instead
retains any already-written prefix on I/O failure and propagates
`std.Io.Writer.Error`; the caller still owns flush/error handling.

The existing `"Unknown"` path is intentionally separate: it keeps its original
`snprintf` count/truncation semantics even for a zero-sized buffer.

## Production boundary and remaining work

Only the owned, numeric relative patterns in `ipmi_timestamp_string`,
`ipmi_timestamp_numeric` and `ipmi_timestamp_date` use this helper now. Their
input is bounded `u32` below `IPMI_TIME_INIT_DONE`, all formats fit the existing
80-byte static buffer, and no locale-dependent words or composite conversions
are used. Static-buffer aliasing and C exports/signatures are unchanged. A
helper error in this bounded internal path is surfaced explicitly and never
falls back to libc.

The CLI calls `setlocale(LC_ALL, "")`. Its non-C-locale behavior must remain
unchanged: generic `ipmi_strftime`, absolute formatting, `ipmi_asctime_r`,
`ipmi_timestamp_time`, and SEL date parsing therefore still use their existing,
explicit libc paths. Completing #228 requires the independent TZif/POSIX TZ
decoder, an ABI adapter with overflow/error handling, and an explicit decision
about non-C locales and unsupported format extensions. This leaf adds no
locale force/reset to production and claims neither full time cutover nor
whole-program no-libc status.

## Focused gates and fixture provenance

`test-time-calendar` runs the standalone module with `link_libc=false` and no C
sources or bridge. It covers four complete 400-year eras, 10000 signed-64-bit
samples, century fixtures, range/invalid-input checks, both formatting
profiles, injected zones, all buffer boundaries and initial/late writer errors.
`test-time-calendar-compile` compiles the same tests without executing a
foreign target. `test-time-calendar-parity` uses the already-translated libc
functions and original `lib/ipmi_time.c` already linked by the ABI test root;
no new tracked C helper or bridge import was added. `test-time-unit` now
selects the complete existing time suite, including fixed offsets/DST and
unchanged `"Unknown"` behavior. The new native and parity gates are in `test`.

The integer-century fixtures are Unix seconds for Gregorian midnight
1600-02-29, 1700/1800/1900-03-01, 1960/2000-02-29, 2100-03-01 and 2400-02-29;
they are independently reproducible by integer `datetime` day/second
differences from 1970-01-01. GNU fixtures were checked against the host glibc
2.43 C locale with `gmtime_r`/`strftime`; musl fixtures were checked against a
temporary, untracked C-locale program compiled by Zig 0.16 for
`aarch64-linux-musl`. The committed differential tests recheck the linked
libc, including year -1/0/1/10000, both `tm_year` limits and rejected epochs,
rather than trusting frozen strings alone.

```sh
zig test src/zig/util/time_calendar.zig
zig build test-time-calendar test-time-calendar-parity test-time-unit \
  -Dzig-modules=all -Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false
zig build test-time-calendar-compile -Dtarget=x86_64-linux-musl \
  -Dzig-modules=all -Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false
```
