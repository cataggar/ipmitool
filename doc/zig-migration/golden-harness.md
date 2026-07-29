# Golden test harness

This is the safety net for the incremental C-to-Zig rewrite tracked in
issue #2. Every module that gets ported has to keep producing **byte identical**
CLI output, and this harness is what proves it.

It works by running an `ipmitool` binary against the built-in `dummy` interface,
feeding that interface from committed transcripts, and comparing four things
against a committed snapshot:

* stdout, byte for byte,
* stderr, byte for byte, captured **separately** from stdout,
* the process exit status,
* the **IPMI request log** - every request the binary sent and every response the
  harness gave it.

The request log matters as much as the printed output. A port that prints the
right thing while sending different IPMI traffic is still a regression, and the
log is what catches it.

* [Quick start](#quick-start)
* [How the dummy interface is driven](#how-the-dummy-interface-is-driven)
* [Layout](#layout)
* [Adding a case](#adding-a-case)
* [Writing a transcript](#writing-a-transcript)
* [Writing a byte-level fixture](#writing-a-byte-level-fixture)
* [Snapshots](#snapshots)
* [Differential mode](#differential-mode)
* [Determinism: what is controlled, what is normalized](#determinism-what-is-controlled-what-is-normalized)
* [Command coverage check](#command-coverage-check)
* [How it is wired into `zig build`](#how-it-is-wired-into-zig-build)

## Quick start

```sh
# The usual way: build and run the suite against what was just built, plus a
# second run against a binary with every registered Zig module swapped in.
zig build test

# Only the golden suite. Extra arguments are forwarded to the harness.
zig build test-golden
zig build test-golden -- --filter fru_
zig build test-golden -- --update

# Standalone, without the build system, against the baseline oracle
# (see baseline-oracle.md).
IPMITOOL_ORACLE=/path/to/oracle/ipmitool ./tests/run.sh

# Run a subset.
./tests/run.sh --binary ./zig-out/bin/ipmitool --filter fru_

# Regenerate snapshots after an intentional change, then review the diff.
./tests/run.sh --update --filter sdr_

# Differential mode: is the Zig build identical to the C build?
./tests/run.sh --binary /path/to/oracle/ipmitool \
               --candidate ./zig-out/bin/ipmitool

# What is covered?
./tests/run.sh --coverage
```

`tests/run.sh` is a thin POSIX shell wrapper around
`zig run tests/golden/main.zig`. The harness needs nothing from `build.zig`, so
it also works against an autotools build, against an archived oracle, and on a
tree where `zig build` is broken.

The binary under test is picked in this order: `--binary`, `$IPMITOOL_BINARY`,
`$IPMITOOL_ORACLE`, `tests/oracle/ipmitool`.

Full option list: `./tests/run.sh --help`.

The report is written to stdout when the run passes and to stderr when it
fails. That is deliberate: `zig build` discards a `Step.Run`'s stdout but
surfaces its stderr as the failure diagnostic, so a failing case prints its diff
under `zig build test` rather than just an exit code.

## How the dummy interface is driven

`src/plugins/dummy/dummy.c` is the interface the harness uses, because it is the
only transport that needs no hardware, no root and no network. Understanding it
precisely also matters for issue #10 (porting the transports), so the protocol
is documented here and in the doc comment of `tests/golden/DummyBmc.zig`.

**The dummy plugin is a client, not a server.** On `open()` it creates an
`AF_UNIX`/`SOCK_STREAM` socket and *connects* to the path in the
`IPMI_DUMMY_SOCK` environment variable, defaulting to `/tmp/.ipmi_dummy`. So the
harness has to be listening on that socket before it spawns ipmitool. The
harness creates a private socket per case under its scratch directory and points
`IPMI_DUMMY_SOCK` at it, so cases never collide and never touch `/tmp`.

The wire protocol is the raw C structs, in native byte order, with no framing
beyond their fixed sizes. On aarch64/x86-64 LP64 that is:

Request, `struct dummy_rq`, **16 bytes**:

| offset | size | field                                                     |
| -----: | ---: | --------------------------------------------------------- |
|      0 |    1 | `msg.netfn`                                               |
|      1 |    1 | `msg.lun`                                                 |
|      2 |    1 | `msg.cmd`                                                 |
|      3 |    1 | `msg.target_cmd`                                          |
|      4 |    2 | `msg.data_len` (native endian)                            |
|      6 |    2 | padding                                                   |
|      8 |    8 | `msg.data` pointer - garbage from the client, ignore it   |

If `data_len` is non-zero, exactly `data_len` payload bytes follow the header.

Response, `struct dummy_rs`, **24 bytes**:

| offset | size | field                                            |
| -----: | ---: | ------------------------------------------------ |
|      0 |    1 | `msg.netfn` - the convention is `request netfn \| 1` |
|      1 |    1 | `msg.cmd`                                        |
|      2 |    1 | `msg.seq`                                        |
|      3 |    1 | `msg.lun`                                        |
|      4 |    1 | `ccode`                                          |
|      5 |    3 | padding                                          |
|      8 |    4 | `data_len` (`int`, native endian)                |
|     12 |    4 | padding                                          |
|     16 |    8 | `data` pointer - ignored by the client           |

followed by `data_len` payload bytes. Responses must not exceed
`IPMI_BUF_SIZE` (1024) bytes of payload.

Two things are easy to get wrong:

* `data_read()` in `dummy.c` loops on short reads but does **not** advance the
  destination pointer, so a response that arrives in more than one `read()` is
  silently corrupted. The harness always writes the header and the payload with
  a single buffered `writeAll` plus `flush`.
* `close()` sends a "BYE" request, netfn `0x3f` / cmd `0xff`, and then closes the
  socket. The harness logs it as `bye` and stops serving that connection.

ipmitool always sends two probes immediately after opening any interface
(`picmg_discover()` then `vita_discover()` from `lib/ipmi_main.c`), so even a
case that only prints usage text produces two exchanges:

```
> netfn=0x2c lun=0x00 cmd=0x00 target_cmd=0x00 data=00
> netfn=0x2c lun=0x00 cmd=0x00 target_cmd=0x00 data=03
```

The harness serves one connection at a time from a concurrent task. When the
child process has exited it connects once more and sends a private shutdown
sentinel (netfn `0xfe`, cmd `0xfe` - outside the 6-bit IPMI netfn range, so a
real client can never emit it) to unblock the `accept` loop. This is
deliberate: cancelling a task that is blocked in `accept` is not reliable, and a
harness that occasionally deadlocks is worse than no harness.

## Layout

```
tests/
  run.sh                    entry point
  golden/
    main.zig                CLI, orchestration, normalization, reporting
    DummyBmc.zig            the dummy-interface server and the request log
    Transcript.zig          .tr grammar and response rule matching
    Case.zig                .cases grammar
    hex.zig                 .hex byte-fixture grammar
    snapshot.zig            .snap render/parse
    diff.zig                the failure diff
    coverage.zig            reads the command table out of src/ipmitool.c
  cases/*.cases             the declarative test cases
  transcripts/*.tr          recorded BMC behaviour
  fixtures/**/*.hex         byte-level fixtures (SDR, FRU, SEL, SPD, HPM, ...)
  fixtures/iana/            trimmed IANA PEN registry
  snapshots/*.snap          the committed expectations
```

Case files are loaded in file-name order and cases run in the order they appear,
so a run is reproducible. The scratch directory (`<repo>/.golden-work` by
default) is recreated per run and deleted afterwards; pass `--keep` to inspect
it.

## Adding a case

Cases live in `tests/cases/*.cases`. Add a block, run with `--update`, **read
the produced snapshot** and commit it.

Keep case names to **36 characters or fewer**. The name becomes a scratch
directory whose `AF_UNIX` socket path must fit in `sockaddr_un.sun_path`, and
the checkout path on the CI runners is longer than a typical local one - a name
that works here can fail with `harness error: SocketPathTooLong` only on CI.

```
[fru_bad_area_checksum]
desc: FRU board area with a corrupt checksum - fields still print, checksum reported INVALID
args: -I dummy fru print 0
transcript: fru_bad_checksum.tr
covers: fru
```

| key          | meaning                                                                    |
| ------------ | -------------------------------------------------------------------------- |
| `desc`       | free text; shown on failure, not part of the snapshot                      |
| `args`       | argv after the binary path; double quotes group words                      |
| `transcript` | file in `tests/transcripts` (default `default.tr`)                         |
| `covers`     | space separated top-level commands this case exercises (feeds the coverage check) |
| `env`        | `NAME=VALUE`, repeatable, added to the fixed environment                   |
| `blob`       | `<dest> <fixture.hex>` - materialize a binary file in the scratch dir      |
| `text`       | `<dest> <fixture.txt>` - materialize a text file in the scratch dir        |
| `registry`   | `default` (plant the IANA PEN fixture) or `none` (test the lookup failure) |
| `timeout_ms` | per-case wall-clock budget, default 10000                                  |

`{work}` in `args` expands to the case's scratch directory, and is scrubbed back
out of the captured output, so file-based commands are stable:

```
[hpm_check_bad_md5]
desc: HPM.1 image whose trailing MD5 does not match the content
args: -I dummy hpm check {work}/fw.img
transcript: hpm.tr
blob: fw.img hpm/image_bad_md5.hex
covers: hpm
```

## Writing a transcript

A transcript (`tests/transcripts/*.tr`) is a list of response *rules*. The first
rule that matches a request, in file order, answers it. Anything unmatched gets
`default_ccode`, which defaults to `0xc1` "Invalid command" - what a BMC that
does not implement an optional command actually returns.

```
default_ccode 0xc1

respond get_device_id     # optional name; it appears in the request log
  netfn 0x06              # required
  cmd   0x01              # required
  lun   0x00              # optional extra match
  match 00 01             # optional match on a prefix of the request data
  times 1                 # optional use limit; default unlimited
  ccode 0x00              # default 0x00
  data  20 81 02          # repeatable, concatenated, hex.zig grammar
  data  @mc/device_id.hex # ... including @include of a byte-level fixture
end
```

Commands that read a large structure in pieces - Get SDR, Read FRU Data, I2C
Master Write-Read - need the response to depend on the offset and length in the
request. That is what `partial` is for: `blob` holds the whole structure and
`partial` says where the offset and count live in the request.

```
respond read_fru_data
  netfn 0x0a
  cmd 0x11
  partial 1 2 3 count_prefix   # offset = request[1..2] little endian,
                               # count  = request[3],
                               # reply starts with the byte count returned
  blob @fru/board.hex
end
```

`partial <offset index> <offset width> <count index> [count_prefix]` returns
`blob[offset .. offset + count]` clamped to the end of the blob, and completion
code `0xc9` (parameter out of range) if the offset is past the end - which is
what a real BMC does. This keeps transcripts independent of how the transport
happens to chunk its reads.

The practical way to build a transcript is iterative: write what you know, run
the case with `--update`, read the `requests` section of the produced snapshot
to see what ipmitool asked for next, add a rule, repeat.

## Writing a byte-level fixture

The binary parsers - SDR records, FRU areas, SEL entries, DIMM SPD,
PICMG/VITA records, HPM.1 images - are the highest risk part of the port and the
historical CVE surface. They get fixtures in `tests/fixtures/`, stored as
commented hex text so every byte is visible in a review diff:

```
01 00        # [1:2]  Record ID = 0x0001
51           # [3]    SDR version 1.5 (51h)
01           # [4]    Record type 01h = Full Sensor Record
34           # [5]    Record length = 52 bytes follow
20           # [6]    Sensor owner ID (BMC, slave address 20h)
```

Directives (`#` starts a comment, offsets are relative to a named `@mark`):

| directive                     | effect                                                     |
| ----------------------------- | ---------------------------------------------------------- |
| `@include p.hex` / `@p.hex`   | splice in another fixture, path relative to `fixtures/`     |
| `@pad 16 0x00`                | emit 16 copies of a byte                                   |
| `@mark name`                  | remember the current offset                                |
| `@checksum name`              | emit the IPMI zero checksum of the bytes since `@mark name` |
| `@size name` / `@size8 name`  | emit the byte count since `@mark name`, or that divided by 8 |
| `@md5 name`                   | emit the MD5 of the bytes since `@mark name` (HPM.1 images) |
| `@truncate 12`                | keep only the first 12 bytes                               |
| `@drop name 5`                | delete 5 bytes starting at `@mark name`                    |
| `@poke name 63 0xff`          | overwrite one byte at `@mark name + 63`; a negative offset counts back from the end |
| `@fill_size name8 area`       | store the size of a region into a byte reserved earlier    |
| `@fill_checksum slot region`  | store a zero checksum into a byte reserved earlier         |

`@fill_size`/`@fill_checksum` exist because FRU areas and HPM.1 records put a
length or a checksum *before* the bytes it covers. Reserve the byte with
`@mark`, emit the content, then fill it in:

```
@mark area
01           # [0] Format version 1
@mark lenslot
00           # [1] Area length / 8 (filled in below)
...
@mark sumslot
00           # zero checksum (filled in below)
@fill_size8 lenslot area
@fill_checksum sumslot area
```

**Malformed variants are the point.** A corrupt fixture should differ from the
good one by one readable line, so the diff shows exactly what was corrupted:

```
# The good FRU image with a single corrupted byte in the board info area.
@mark image
@fru/board.hex
@poke image 63 0xff   # board area checksum byte (area at 32, length 64)
```

Current parser fixtures:

| directory              | fixtures                                                               |
| ---------------------- | ---------------------------------------------------------------------- |
| `fixtures/sdr/`        | full sensor, compact sensor, event-only, FRU device locator records     |
| `fixtures/fru/`        | common header, chassis/board/product/multirecord areas, plus bad checksum, bad common header, truncated and out-of-range-offset variants |
| `fixtures/sel/`        | threshold event, discrete event, OEM timestamped, OEM non-timestamped, short entry |
| `fixtures/spd/`        | JEDEC DDR3 SPD image and a short-read variant                          |
| `fixtures/hpm/`        | valid HPM.1 image, bad MD5, bad signature, truncated                    |
| `fixtures/mc/`         | Get Device ID response, system GUID                                     |
| `fixtures/iana/`       | trimmed IANA enterprise-numbers registry                                |

PICMG and VITA records are exercised through `transcripts/picmg.tr` and
`transcripts/vita.tr`, since those records are only ever seen as command
responses rather than as stored structures.

## Snapshots

A snapshot is a text file with four sections:

```
#!golden 1
#!case mc_info
#!section exit
0
#!section stdout
Device ID                 : 32
...
#!section stderr
#!section requests
> netfn=0x06 lun=0x00 cmd=0x01 target_cmd=0x00 data=
< rule=get_device_id ccode=0x00 len=15 data=20 81 02 03 02 bf 57 01 00 01 00 00 00 00 00
bye
```

Because output has to be compared byte for byte, the format escapes what a text
diff would otherwise destroy: a trailing space becomes `\x20`, a tab becomes
`\t`, any other non-printable byte becomes `\xNN`, a literal backslash becomes
`\\`, and a line that would start with `#!` is escaped as `\x23!`. A stream that
does not end in a newline is marked `#!section stdout no-final-newline`.

`--update`/`--accept` rewrites snapshots. Always read the resulting diff before
committing: an unreviewed snapshot update is how a real regression gets blessed.

## Differential mode

```sh
./tests/run.sh --binary /path/to/oracle/ipmitool --candidate ./zig-out/bin/ipmitool
```

Both binaries run over every case, each with its own fresh dummy BMC and its own
scratch directory, and their outputs are diffed **against each other** rather
than against the snapshots. This is the mode future port PRs should use: it
answers "does the Zig build behave exactly like the C build *right now*",
without needing the snapshots to be up to date.

It exits non-zero on the first differing case and prints the same diff format as
snapshot mode:

```
FAIL mc_info: reference and candidate differ (Get Device ID ...)
  --- stdout ---
   Device Revision           : 1
  -Firmware Revision         : 2.03
  +Firmware  Revision         : 2.03
   IPMI Version              : 2.0
```

## Determinism: what is controlled, what is normalized

The bias is heavily towards **controlling** the environment rather than
scrubbing the output, because a blanket scrubber can hide a real regression.

Controlled - each case runs with exactly this environment, nothing inherited:

| variable           | value                     | why                                                              |
| ------------------ | ------------------------- | ---------------------------------------------------------------- |
| `PATH`             | `/usr/bin:/bin`           | no user PATH leaking in                                           |
| `HOME`             | `<work>/home`             | so the IANA registry lookup is under harness control              |
| `TZ`               | `UTC`                     | SEL and FRU dates are formatted with `localtime`                  |
| `LC_ALL`, `LANG`   | `C`                       | `lib/ipmi_main.c` calls `setlocale(LC_ALL, "")`                   |
| `TERM`             | `dumb`                    | keeps readline and any terminal probing out of the output         |
| `COLUMNS`          | `80`                      | pins anything width dependent                                     |
| `IPMI_DUMMY_SOCK`  | `<work>/s`                | the per-case dummy socket                                         |

stdin is `/dev/null`, so commands that prompt (for example `hpm check` asking
"Continue (Y/N)") get EOF deterministically instead of hanging.

Two further sources of nondeterminism are removed by construction rather than by
scrubbing:

* **argv[0].** `lib/ipmi_main.c` derives `progname` from `basename(argv[0])` and
  prints it in usage text and getopt errors. Before each case the harness
  creates a symlink `<work>/bin/ipmitool` pointing at the binary under test and
  execs *that*, so a candidate named `ipmitool-zig`, or a wrapper script, cannot
  produce a spurious diff against the oracle.
* **The IANA PEN registry.** `oem_info_list_load()` in `lib/ipmi_strings.c`
  reads `$HOME/.local/usr/share/misc/enterprise-numbers` first and then the
  compiled-in `IANADIR`. The harness plants a small committed registry fixture
  under the per-case `$HOME`, so manufacturer names resolve identically on any
  machine. `registry: none` in a case tests the not-found path instead.

Normalized - and this is the complete list, three explicit substitutions:

| pattern                                                | replacement  | why                                                            |
| ------------------------------------------------------ | ------------ | -------------------------------------------------------------- |
| the token after `ipmitool version ` / `ipmievd version ` | `<VERSION>` | the version string changes on every release                     |
| the absolute path of the case's scratch directory       | `<WORK>`     | it contains a per-run temporary path                            |
| the absolute path of the binary under test              | `<BINARY>`   | belt and braces, in case a message embeds the resolved real path |

There is deliberately no regex for timestamps, PIDs or hostnames: every
timestamp in the output comes from a fixture, and anything that would print a
PID or a hostname is either not exercised or would be a genuine finding.

## Command coverage check

Coverage is computed from the C command table, not from a hand-maintained list.
`tests/golden/coverage.zig` parses `ipmitool_cmd_list[]` out of `src/ipmitool.c`
and cross-references it with the `covers:` key of every case. A command with no
case, or with no `<cmd> help` case, fails the run:

```
coverage: 38/39 commands (97%), 38/39 help paths (97%)
  commands with no case: zzz
  commands with no help case: zzz
```

So when a future PR adds a command, the suite fails until that command has a
test. `--allow-uncovered` suppresses the failure; it exists for local
experiments and should not be used in CI.

## How it is wired into `zig build`

`build.zig` compiles `tests/golden/main.zig` into a `golden` host executable and
runs it. Two steps exist:

| step                    | what it does                                                     |
| ----------------------- | ---------------------------------------------------------------- |
| `zig build test-golden` | the golden suite only                                             |
| `zig build test`        | the ABI/layout assertions, the smoke tests, and `test-golden`     |

`zig build test` is what CI runs (`.github/workflows/ci.yml`, the `test` job),
so every pull request is gated on the suite.

### Two binaries per run

`test-golden` runs the suite **twice**:

1. against the binary the current options produce, which by default is all C,
   and
2. against `ipmitool-zig`, a binary with *every* module registered in
   `zig_modules` served by Zig.

The second run is what makes this a migration safety net rather than a
regression test: it proves that the ported Zig modules produce byte-identical
stdout, stderr, exit status and IPMI request bytes. Because the two binaries
share their C objects through the compilation cache, the second one costs a
static archive and two links - about 3 s here, against roughly 10 s for the
build itself.

When `-Dzig-modules` already selects everything, the two binaries would be
identical and the second run is skipped, so `zig build test -Dzig-modules=oem`
runs the suite once, against the swapped binary.

Adding a module to `zig_modules` automatically extends the swapped build; there
is nothing to update in the test wiring.

### Arguments

Everything after `--` is forwarded to the harness:

```sh
zig build test-golden -- --filter sel_
zig build test-golden -- --update
zig build test -- -v
```

### Scratch space

Under `zig build` each run gets a private scratch root inside `.zig-cache`
(`b.tmpPath()`), because the two runs are independent steps that the build
runner may execute concurrently. Run standalone, the harness uses
`<repo>/.golden-work`, which is in `.gitignore` and removed on exit.

## Related

* `doc/zig-migration/baseline-oracle.md` - how the reference binaries are built
  (`scripts/build-oracle.sh`). The oracle is what the snapshots in this
  directory were generated from.
* `doc/zig-migration/interop-seams.md` - the `-Dzig-modules` swap flag and the
  per-module port checklist. The golden suite is the acceptance test for every
  entry on that checklist.
