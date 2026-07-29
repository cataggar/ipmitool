# Transport fixtures

Byte-level verification infrastructure for the transport layer (issue #10),
built to close the coverage boundary reported in issue #26.

`zig build test-transport` (also reached by `zig build test`) runs the real
`ipmitool` binary against a **model BMC** over loopback UDP and byte-compares
every datagram in both directions against a checked-in transcript.

## Why this exists

The 173-case golden suite (`tests/golden/`, see `golden-harness.md`) drives
every case through the `dummy` interface.  `dummy` is a UNIX-socket echo
service: it has no checksums, no session layer, no packet assembly and no
retry logic.  Everything Phase 4 is about is therefore invisible to it.

The demonstration in #26 is one line in `lib/helper.c`:

```c
 uint8_t ipmi_csum(uint8_t *d, int s)
 {
 	uint8_t c = 0;
 	for (; s > 0; s--, d++)
 		c += *d;
-	return -c;
+	return 1 - c;
 }
```

Every checksum ipmitool computes is now wrong by one, and the golden suite
still reports `173 passed, 0 failed`.  A regression like that would ship green
and only appear against real BMC hardware, which CI cannot reach.

This harness turns that same mutation into 32 failures out of 33 cases.

## Design

### A model BMC, not a recorded replay

The obvious design — freeze the bytes a real BMC sent and replay them — does
not work for RMCP+.  The BMC's RAKP 2 authcode, the session integrity key, the
integrity codes on every packet and the AES ciphertext all depend on the 16
random bytes the *client* picks in RAKP 1.  Frozen response bytes would fail
to verify against a fresh client nonce and the session would never open, so
the harness would only ever cover the first three datagrams.

`tests/transport/Bmc.zig` is instead a small, deterministic, *semantic* BMC.
It parses what it receives, checks it, and computes a correct answer, using a
fixed identity (session ids, challenge, `Rc`, GUID) so that everything not
derived from client randomness is byte-stable.

Every source of nondeterminism is fixed or masked:

| source | treatment |
| --- | --- |
| the client's ephemeral UDP port | the port is substituted out of the transcript |
| the 4 random bytes in Activate Session | masked, along with the `csum2` and MD5 authcode derived from them |
| the client's 16-byte `Rm` in RAKP 1 | masked |
| SIK-derived integrity codes | masked (but *verified*, see below) |
| AES ciphertext and IV | masked (but *decrypted*, see below) |
| the BMC's own `Rc`, session id, GUID | fixed constants in `Personality` |
| the AES IV the BMC emits | derived from the session sequence number; the client cannot tell, because the IV is transmitted in the packet |
| the scratch directory path | substituted out of stderr |
| the IANA enterprise-number registry | `tests/fixtures/iana/enterprise-numbers` is copied into a per-case `$HOME` so `mc info` output does not depend on the machine |

### One stateful responder, on purpose

The model BMC answers from a fixed table (`Personality.extra`): the reply does
not depend on the request body.  There is one exception, `Personality.fru`,
which serves a byte image through `Get FRU Inventory Area Info` and
`Read FRU Data`.

It exists because `read_fru_area()` sizes every `Read FRU Data` request as
`ipmi_intf_get_max_response_data_size(intf) - 2` and puts that count in the
request, so the payload-size arithmetic in `src/plugins/ipmi_intf.c` — which
is otherwise invisible, since nothing else on the wire depends on it — becomes
a byte in the transcript.  The three `lan/md5-fru*` cases read the same image
at bridging levels 0, 1 and 2 and record chunk sizes of 32, 23 and 15
respectively.

### One code path for record and check

`zig build gen-transport-fixtures` and `zig build test-transport` run the same
executable with the same model BMC; the only difference is whether the
transcript is written or compared.  There is no separate replay implementation
that could drift away from the recorder, and no way for a fixture to encode a
behaviour the checker does not also enforce.

This is the transport-layer form of crypto lesson 2 (*"tests that
re-implement a wrapper cover nothing inside it"*): the thing under test is the
shipped `ipmitool` binary, driven as a subprocess through its real
command-line, not a Zig reimplementation of its packet writer.

### Two independent detectors

A case fails if **either**

1. the transcript differs from the fixture, byte for byte, or
2. the model BMC recorded a protocol violation.

The BMC independently recomputes both IPMI checksums, both RMCP+ integrity
codes, the RAKP 2/3 authcodes and the confidentiality padding; it checks the
declared message length against the datagram length, the session id against
the one it issued, and that the session sequence number strictly increases.
Each verdict is written into the transcript (`csum1=c8:ok`,
`authcode=BAD`, `pad=ok`) and a bad one also increments a violation counter.

That means a mutation is caught even in the two situations where a pure
snapshot would not notice:

- a byte the harness masks (an integrity code, an AES payload) is wrong — the
  transcript still matches, but `ich authcode=BAD` and the counter fires;
- a fixture is regenerated by someone who did not read the diff — the
  regenerated fixture *still* contains `:BAD` markers and the run still fails.

The second property is the important one for a future port PR: `--update`
cannot be used to paper over a broken implementation.

### Independent crypto

`tests/transport/crypto.zig` implements the BMC side of RAKP, HMAC, key
derivation and AES-CBC directly on `std.crypto`.  It deliberately does **not**
import `src/zig/crypto/`.

If it did, a future Zig `lanplus` port would be verified against itself and
every RMCP+ assertion would become a tautology.  `src/zig/crypto/` is already
verified independently, against 681 vectors captured from OpenSSL (see
`crypto.md`), so using a second implementation here costs nothing and keeps
the two layers honest.

## Transcript format

Fixtures are line-oriented text so a reviewer can read a diff.  Example
(`tests/transport/fixtures/lan-none-mc-info.txt`):

```
# case  lan/none-mc-info
# desc  v1.5 session with authtype NONE, then Get Device ID
# args  ipmitool -I lan -H 127.0.0.1 -p ${port} -U  -P  mc info
003 --> 23 ipmi.v15 rq
  raw 06 00 ff 07 00 00 00 00 00 00 00 00 00 09 20 18
  raw c8 81 04 38 0e 04 31
  ssn authtype=00 seq=00000000 id=00000000 msglen=09
  req rsaddr=20 netfn=06 lun=0 csum1=c8:ok rqaddr=81 rqseq=01 lun=0 cmd=38 csum2=31:ok
  dat 0e 04
```

| element | meaning |
| --- | --- |
| `NNN --> LEN kind` | datagram number, direction (`-->` to the BMC, `<--` from it), UDP payload length, and what the BMC decoded it as |
| `raw` | the datagram, 16 bytes per line.  `??` marks a masked byte |
| `asf` | decoded RMCP/ASF presence ping or pong |
| `ssn` | decoded session header (v1.5 or RMCP+) |
| `req` / `rsp` | decoded IPMI message header with checksum verdicts |
| `dat` | the message data field, or `-` when empty |
| `ccc` | completion code of a response |
| `brg` | one level of `Send Message` bridging unwrapped |
| `ich` | RMCP+ integrity check verdict |
| `cnf` | RMCP+ confidentiality: padding verdict and recovered plaintext length |
| `pln` | the decrypted RMCP+ payload |
| `osr` / `rk1` / `rk3` | decoded Open Session Request, RAKP 1, RAKP 3 |
| `!!!` | a protocol violation the BMC detected |
| `(dropped: no response)` | the BMC deliberately ignored this datagram |
| `exit`, `out`, `err` | the process exit status and its captured stdout/stderr, each output line prefixed with `\|` |

## Length pinning by construction

Crypto lesson 1: *a correctness vector cannot pin a length*.  If a field is
correct end to end, a candidate implementation that computes the same value
over a shorter or longer range is indistinguishable.  Pinning the range
requires an input where the candidate ranges **disagree**.

`ipmi_csum()` is a two's-complement sum, so a checksum range that has a zero
byte at either boundary is not pinned: extending or shrinking the range across
that zero produces the identical checksum.  Every case that exists to pin a
checksum therefore uses a payload whose **boundary bytes are non-zero**, and
`lan/md5-raw-long` additionally uses a payload of all-distinct bytes so that a
transposition inside the range is visible in the hex even though the sum would
not change.

The reverse case is `lan/md5-raw-zeros`, which uses a payload with **embedded
NULs**.  A length byte computed as `data_len + 7` and a length byte derived by
scanning for a terminator are indistinguishable unless the data contains a
zero, so that case is what pins the message-length computation.

### A finding: growing a checksum range by one is not a bug

Mutating `lan.c` so that the second checksum is computed over one byte *more*
than it should be produces no observable difference.  The C writes the packet
into a zeroed buffer, and the byte one past the end of the range is the
not-yet-written checksum slot itself, i.e. still zero.  Summing an extra zero
changes nothing.

That is a semantically equivalent implementation, not a defect, and the
harness correctly does not flag it.  Shrinking the range *is* caught (M2),
provided the boundary byte is non-zero — which is exactly why the payloads are
chosen the way they are.

### Masked fields are still length-pinned

Masking a byte range removes the *value* from the comparison, never the
*position* or the *length*.  The Activate Session checksum renders as
`csum2=??:ok`: its value depends on the 4 random bytes, so it is masked, but
its offset is pinned by the surrounding `raw` lines and its **correctness** is
still asserted by the BMC.  Likewise an RMCP+ packet masks the ciphertext but
prints the decrypted `pln` line, so the inner request — headers, checksums,
data — is pinned byte for byte.

MD5 authcodes on every v1.5 packet *other than* Activate Session are fully
deterministic and are pinned byte for byte, which puts `ipmi_auth_md5` under
test on the wire.

### The same rule applies to the model BMC's own constants

A fixture cannot pin a field the tool copies back onto the wire unless the
value in that field makes the candidate serialisations *disagree*.  Every
constant in `Bmc.zig` that the tool has to re-emit or re-parse therefore uses
**four distinct non-zero bytes** (sixteen for the 16-byte blobs).

The rule was learned the hard way.  `inbound_seq` was originally
`0x00000101`, whose top two bytes are zero, so `(s->in_seq >> 16)` and
`(s->in_seq >> 24)` produced the same byte and the v1.5 session sequence
number's byte order was not pinned at the high end at all — mutation M11 below
survived.  With `inbound_seq = 0x51627384` it fails 12 cases.

Both halves of the rule matter:

- **distinct** kills shift-amount and byte-order mutations, because every
  candidate byte differs from every other;
- **non-zero** kills short-write and truncation mutations, because the C
  assembles packets in a zeroed buffer, so a byte that is never written is
  indistinguishable from a byte that is written as zero.

The audited constants and the reasoning for each are in the doc comments in
`Bmc.zig`; the two protocol-mandated exceptions are `asf_rmcp_iana`
(`0x000011be`, fixed by the ASF spec) and the fixed IPMI addresses
`IPMI_BMC_SLAVE_ADDR`/`IPMI_REMOTE_SWID`, which are single bytes.

## Coverage

33 cases, `tests/transport/cases.zig`.

| area | cases |
| --- | --- |
| `ipmi_csum()` on the wire, both ranges | every `lan`/`lanplus` case; pinned by `lan/md5-raw-long` |
| RMCP header assembly, ASF presence ping/pong | every `lan` case; `lan/none-ping-retry`, `lan/oem-supermicro` |
| IPMI v1.5 session activation (0x38 / 0x39 / 0x3a / 0x3b / 0x3c) | `lan/none-mc-info`, `lan/md5-mc-info` |
| v1.5 authtype NONE / MD5 / OEM authcode generation | `lan/none-mc-info`, `lan/md5-mc-info`, `lan/oem-supermicro` |
| v1.5 session sequence numbering, little-endian, all four bytes | all `lan` cases (M3, M7, M11) |
| `rq_seq` allocation and retransmission reuse | `lan/none-retry` (M6) |
| message-length byte computation | `lan/md5-raw-zeros` (M5) |
| response length parsing on receive | all `lan` cases (M15) |
| netfn/lun packing for a non-App netfn | `lan/md5-chassis-status` |
| the LUN reaching the wire in the low two bits of the netfn byte | `lan/md5-raw-lun` (M12) |
| retry limit, exactly | `lan/none-timeout`, `lanplus/cipher3-timeout` (M4) |
| retry then success | `lan/none-retry`, `lan/none-ping-retry`, `lanplus/cipher3-retry` |
| session-setup error paths | `lan/authcap-error`, `lan/activate-error` |
| single and double `Send Message` bridging | `lan/md5-bridged`, `lan/md5-double-bridged` |
| double bridging selected by the *transit channel* rather than the transit address | `lan/md5-fru-transit-channel` |
| `ipmi_intf_get_max_response_data_size()` at bridging level 0, 1 and 2, including the clamp back to the default payload size | `lan/md5-fru`, `lan/md5-fru-bridged`, `lan/md5-fru-transit-channel` |
| `ipmi_intf_session_set_username()` copying exactly 16 bytes | `lan/md5-long-creds`, `lanplus/cipher3-long-creds` |
| `ipmi_intf_session_set_password()` copying exactly 20 bytes | `lanplus/cipher3-long-creds` |
| `ipmi_intf_session_set_authtype()` clearing the password for authtype NONE | `lan/authtype-none-clears-password` |
| RMCP+ Open Session Request/Response | every `lanplus` case |
| RAKP 1–4, including the unencrypted RAKP 4 framing | every `lanplus` case |
| RAKP-HMAC-SHA1 and RAKP-HMAC-SHA256 | `lanplus/cipher1-mc-info`, `lanplus/cipher17-mc-info` |
| HMAC-SHA1-96 and HMAC-SHA256-128 integrity, pad byte and next-header | `lanplus/cipher3-mc-info`, `lanplus/cipher17-mc-info` (M9) |
| AES-CBC-128 confidentiality and its padding rule | `lanplus/cipher3-mc-info`, `lanplus/cipher3-raw-pad` |
| two-key (Kg) login | `lanplus/cipher3-kg` |
| RMCP+ payload-size field, low byte | `lanplus/cipher1-raw-long` (M8) |
| RMCP+ payload-size field, **high** byte, sent and received | `lanplus/cipher1-raw-big` (M13, M14) |
| RMCP+ privilege lookup bit | all `lanplus` cases (M10) |
| RMCP+ failure paths | `lanplus/open-session-error`, `lanplus/rakp2-error`, `lanplus/rakp2-bad-authcode` |
| `ipmi_intf` registry lookup failure | `intf/unknown` |

`ipmi_intf` vtable dispatch is covered structurally rather than by a
dedicated case: every `lan`/`lanplus` case reaches the wire only through
`intf->open`, `intf->sendrecv`, `intf->set_my_addr` and `intf->close`, so a
vtable wired to the wrong slot cannot produce a matching transcript.
`intf/unknown` covers the registry lookup and its error message.

## What this deliberately does **not** cover

Stating this plainly matters more than the coverage table, because it is what
a future port PR still has to argue about separately.

- **Interfaces other than `lan` and `lanplus`.**  `serial-terminal`,
  `serial-basic`, `usb`, and `open` (the Linux `/dev/ipmi0` ioctl interface)
  are not network protocols; there is no datagram to compare.  `imb`,
  `lipmi`, `bmc`, `free` and `dbus` likewise.  Any port of those needs
  different evidence.
- **SOL and `ipmievd`.**  Both are long-lived, event-driven and stateful in
  ways a one-shot subprocess run cannot exercise.  `sol activate` in
  particular takes over the terminal.
- **FRU *contents*.**  The FRU responder exists to expose the Read FRU Data
  chunk size, not to model a FRU device.  The image is a minimal well-formed
  one; what `ipmi_fru.c` makes of the area contents is the golden suite's job.
- **Real BMC quirks.**  The model BMC is a *correct* BMC.  It does not
  reproduce vendor deviations, truncated responses, out-of-order datagrams,
  or the `-o` OEM workarounds beyond `supermicro`'s ping suppression.
- **The response authcode.**  ipmitool never validates the authcode on a
  received v1.5 packet, so the model BMC sends 16 zero bytes.  The 16-byte
  *skip* is pinned (a wrong skip misparses the message and fails), the
  *contents* are not.
- **The BMC's choice of outbound sequence numbers.**  ipmitool does not check
  them, and neither does the fixture.
- **Big-endian hosts and IPv6.**  Every fixture was recorded on
  little-endian; `-6`/`-4` address selection is untested.
- **PRNG quality.**  That the 4 activation bytes and `Rm` are random is
  assumed, not asserted; the harness only asserts that whatever they are, the
  values derived from them are correct.  `crypto.md` covers the PRNG itself.
- **Cipher-suite discovery.**  `-C` is exercised for suites 1, 3 and 17 only;
  the model BMC answers `Get Channel Cipher Suites` with `0xC1`, which is the
  path a BMC that does not implement it takes.
- **Timing.**  The retry cases pin the *number* of retransmissions, not the
  interval between them.  A mutation that only changed the backoff would not
  be caught.
- **Response payload *interpretation*.**  The harness pins the bytes that cross
  the wire and the process's stdout/stderr; what a command module makes of a
  response body is the golden suite's job.  A `Get Device ID` reply whose
  manufacturer id has a zero high byte, for example, does not pin that
  `ipmi_mc.c` reads three bytes rather than two — that is out of scope here.
- **Bridging beyond two levels.**  The model BMC unwraps at most two nested
  `Send Message` wrappers, which is what `-t` and `-T`/`-B` produce.

## Mutation battery

Each row is one mutation applied to the C source, rebuilt, run.  The counts in
this first table were measured against the original 27-case suite; the
baseline is now `33 passed, 0 failed`, so the failure counts are lower bounds.

| # | file | mutation | transport result |
| --- | --- | --- | --- |
| M1 | `lib/helper.c` | `ipmi_csum` returns `1 - sum` instead of `-sum` | **1 passed, 26 failed** |
| M2 | `lan.c` | second checksum range starts one byte early (`cs = len` → `cs = len - 1`) | 13 passed, **14 failed** |
| M3 | `lan.c` | session sequence advances by two (`s->in_seq++` → `+= 2`) | 15 passed, **12 failed** |
| M4 | `lan.c` | `IPMI_LAN_RETRY` 4 → 3 | 25 passed, **2 failed** |
| M5 | `lan.c` | message length byte `data_len + 7` → `+ 6` | 13 passed, **14 failed** |
| M6 | `lan.c` | `curr_seq` never advances | 13 passed, **14 failed** |
| M7 | `lan.c` | v1.5 session sequence written big-endian | 15 passed, **12 failed** |
| M8 | `lanplus.c` | RMCP+ payload-size field one byte short | 15 passed, **12 failed** |
| M9 | `lanplus.c` | RMCP+ integrity pad byte `0xFF` → `0x00` | 21 passed, **6 failed** |
| M10 | `lanplus.c` | RAKP 1 drops the privilege lookup bit | 16 passed, **11 failed** |
| M11 | `lan.c` | v1.5 session sequence top byte uses `>> 16` instead of `>> 24` | 15 passed, **12 failed** |
| M12 | `lan.c` | LUN dropped from the netfn/lun byte | 26 passed, **1 failed** |
| M13 | `lanplus.c` | RMCP+ payload-size high byte never written | 26 passed, **1 failed** |
| M14 | `lanplus.c` | RMCP+ payload-size high byte ignored on receive | 26 passed, **1 failed** |
| M15 | `lan.c` | response `data_len` over-trimmed by one on receive | 13 passed, **14 failed** |

M1 is the case from #26.  With it applied:

```
$ golden  --binary .../ipmitool
golden [snapshot]: 173 passed, 0 failed, 0 filtered out (173 cases total)
coverage: 38/38 commands (100%), 38/38 help paths (100%)

$ transport-fixtures --binary .../ipmitool
FAIL lan/none-mc-info
      the model BMC reported 20 protocol violation(s); see '!!!' below
...
      003 --> 23 ipmi.v15 rq
        raw 06 00 ff 07 00 00 00 00 00 00 00 00 00 09 20 18
        raw c9 81 04 38 0e 04 32
        req rsaddr=20 netfn=06 lun=0 csum1=c9:BAD ... csum2=32:BAD
        !!! header checksum wrong: expected c8
        !!! data checksum wrong: expected 31
...
transport fixtures: 1 passed, 26 failed, 0 skipped
```

The one survivor is `intf/unknown`, which fails to load an interface and
never sends a packet.

M4 is the reason the retry cases exist in two flavours.  A case where the BMC
ignores *N* datagrams and then answers pins the retry count only from below:
raising the limit still passes.  `lan/none-timeout` and
`lanplus/cipher3-timeout` use a BMC that never answers one particular
netfn/cmd, so the transcript contains every retransmission the tool makes and
the count is pinned exactly in both directions.  Those cases deliberately do
**not** pass `-R`, so the compiled-in `IPMI_LAN_RETRY` is what is under test.

M11 is the mutation that motivated the constant audit above.  Against the
original `inbound_seq = 0x00000101` it survived; against `0x51627384` it fails
12 cases.

### `src/plugins/ipmi_intf.c` → `src/zig/intf/registry.zig`

Applied to the Zig port, built with `-Dzig-modules=intf`.  Baseline is
`33 passed, 0 failed` on the transport suite and `922 passed, 0 failed` on the
golden suite.  Every row leaves the golden suite at `922 passed, 0 failed` and
`ipmitool -h` byte-identical, which is the point: none of this is visible
above the transport layer.

| # | mutation | transport result | caught by |
| --- | --- | --- | --- |
| N1 | `ipmi_intf_session_set_username()` copies 15 bytes instead of 16 | 31 passed, **2 failed** | `lan/md5-long-creds`, `lanplus/cipher3-long-creds` |
| N2 | `ipmi_intf_session_set_password()` copies 16 bytes instead of 20 | 32 passed, **1 failed** | `lanplus/cipher3-long-creds` (RAKP 2 authcode fails BMC-side verification) |
| N3 | `ipmi_intf_get_bridging_level()` drops the `transit_channel != target_channel` clause | 32 passed, **1 failed** | `lan/md5-fru-transit-channel` |
| N4 | `ipmi_intf_get_max_response_data_size()` drops the clamp back to the default payload size | 31 passed, **2 failed** | `lan/md5-fru-bridged`, `lan/md5-fru-transit-channel` |
| N5 | `ipmi_intf_get_max_response_data_size()` drops the second `-8` for double bridging | 32 passed, **1 failed** | `lan/md5-fru-transit-channel` |
| N6 | `ipmi_intf_load()` matches with `strncmp(name, entry, 3)` instead of `strcmp` | 20 passed, **13 failed** | every `lanplus` case (loads `lan`) plus `intf/unknown` |
| N7 | `ipmi_intf_session_set_authtype()` no longer clears the password for authtype NONE | 32 passed, **1 failed** | `lan/authtype-none-clears-password` |
| M1 | re-run of M1 (`ipmi_csum` returns `1 - sum`) against the swapped binary | **1 passed, 32 failed** | everything except `intf/unknown` |

Four more mutations are caught only by the unit tests in
`src/zig/intf/registry.zig`, because no CLI input reaches them:

| # | mutation | caught by |
| --- | --- | --- |
| N8 | `set_password()` copies 21 bytes instead of 20 | unit test: `-P` is capped at 20 bytes by `lib/ipmi_main.c`, so the 21st byte is never non-zero on the wire |
| N9 | `get_max_request_data_size()` drops the second `-8` for double bridging | unit test: the only consumers are FRU *write* and the HPM firmware upgrade, both of which need a local image file the harness does not provide |
| N10 | `defaultInterface()` always returns the first table entry | unit test with a synthetic table: `DEFAULT_INTF` is `open`, which *is* the first entry in every configuration CI builds |
| N11 | `IN6_IS_ADDR_LINKLOCAL` mask `0xc0` → `0xe0` | unit test: fixtures connect to `127.0.0.1`, so no IPv6 classification runs.  The unit test needs `fea0::` as well as `fe80::` — the two masks agree on `fe80::` |

### Documented equivalent mutants

These survive and are **not** defects.  They are recorded so a future reviewer
does not read them as a gap.

| mutation | why it is equivalent |
| --- | --- |
| `lan.c`: `req->msg.lun & 3` → `& 7` | `struct ipmi_rq.msg.lun` is declared `uint8_t lun:2` (`include/ipmitool/ipmi.h:74`), so the field cannot hold a value above 3 and the two masks agree for every reachable input.  `-l 7` *is* accepted by `str2uchar` and reaches `intf->target_lun`, but `ipmi_raw` truncates it the moment it assigns into the bitfield.  No CLI input can separate the two masks; the mask is dead code.  `lan/md5-raw-lun` still earns its place — it is the only case that catches M12, dropping the LUN from the byte entirely. |
| growing an `ipmi_csum` range by one byte | see the section above: the extra byte is the not-yet-written checksum slot in a zeroed buffer, so the sum is unchanged.  Shrinking the range *is* caught (M2). |
| `ipmi_intf.c`: `ipmi_intf_session_set_kgkey()` copies 20 bytes instead of `IPMI_KG_BUFFER_SIZE` (21) | `-k` is capped at 20 characters, so the 21st byte of the source buffer is always the NUL terminator and the destination is already zero.  No CLI input separates the two lengths.  The unit test still pins the full 21-byte copy. |
| `ipmi_intf.c`: `ipmi_intf_get_max_response_data_size()` drops the first `-8` (the one applied *before* the clamp) | `lan` and `lanplus` both declare `max_response_data_size = 34`.  At bridging level 1 the value is clamped to the 25-byte default with or without the subtraction, and level 2 subtracts 8 from that same clamped 25 either way.  The mutation is only observable for an interface declaring between 26 and 32 bytes, and none exists. |
| `ipmi_intf.c`: `ipmi_intf_get_max_response_data_size()` adds 8 instead of 7 when no size is declared | the `size == 0` branch only runs for an interface that never sets `max_response_data_size`.  Every network interface sets it, and there is no CLI option to zero it (`-z` only sets the *request* size), so the branch is unreachable from the fixtures. |

## Running it

```
zig build test-transport             # compare against checked-in fixtures
zig build test                       # includes the above
zig build gen-transport-fixtures     # re-record (writes into the source tree)
```

Extra arguments are forwarded:

```
zig build test-transport -- --filter lanplus     # substring match on case name
zig build test-transport -- -v                   # print every transcript
zig build test-transport -- --list
```

The suite binds `127.0.0.1:0` and needs no hardware, no privileges and no
external network.  When `lan` or `lanplus` are disabled (`-Dplugins=...`) the
step degrades to the unit tests only, because there is nothing to check.

`test-transport` runs the suite twice when a partial `-Dzig-modules` selection
is active: once against the default binary and once against the swapped one,
matching how `test-golden` works.

## How a port PR uses this as evidence

A PR that ports any part of `lan`, `lanplus`, `ipmi_intf` or `helper.c`'s
checksum to Zig is expected to:

1. Leave `tests/transport/fixtures/` **unchanged**, and show
   `zig build test-transport` passing.  The fixtures are the specification;
   the Zig transport must put the same bytes on the wire as the C one.
2. If a fixture genuinely must change, justify it **byte by byte** in the PR
   body.  `--update` regenerating a clean diff is not evidence — the harness
   is designed so a broken implementation still produces `:BAD` markers in the
   regenerated file, but a *behaviour* change (an extra probe command, a
   different sequence seed) will regenerate cleanly and must be argued for.
3. Add cases for anything the port introduces that no existing case reaches,
   and say in the PR body which mutation would have caught it.  If the new
   case involves a constant the tool has to re-emit, apply the four-distinct-
   non-zero-bytes rule to it.
4. Re-run at least M1 from the battery above against the ported code and paste
   the result, to show the new implementation is still under the harness and
   has not accidentally been routed around it.
