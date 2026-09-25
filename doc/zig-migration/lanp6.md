# IPv6 LAN configuration port

`zig build -Dzig-modules=lanp6` selects `src/zig/cmd/lanp6.zig` in place of
`lib/ipmi_lanp6.c`. The shared C `lib/ipmi_cfgp.c` still handles parameter
selection, read-all/set-all iteration and save/print dispatch. The Zig module
provides all 21 parameter descriptors, their parsing and formatting, and the
Get/Set LAN Configuration wire operations. It exports the original C entry
points **and** the global LAN6 descriptor/value tables. `struct ipmi_cfgp` has
C bitfields; the Zig descriptor's layout is checked against compiler-derived
sizes and offsets in `abi_layout.h`.

The `tests/cases/57-lanp6.cases` matrix and `lan6_*.tr` transcripts were
recorded against an all-C binary before enabling the Zig port. They cover all
21 printable parameters, save and help variants, all writable parameter
classes, both static routers and the multi-request DHCPv6 and dynamic-router
records, lock/commit/discard and `nolock`, scans, invalid inputs, short
successful replies, denied reads/writes, partial failure and the resulting
wire requests. Run the C and Zig implementations against the same recorded
BMC responses:

```sh
zig build -Dzig-modules=lanp6
zig build test-lanp6-unit -Dzig-modules=lanp6
./tests/run.sh --binary /path/to/all-c/ipmitool \
  --candidate ./zig-out/bin/ipmitool --filter lan6_
```

Intentional hardening for *invalid* inputs/replies only:

* Channels outside `0..14`, set/block selectors outside `0..255`, and IPv6
  prefix lengths outside `0..128` fail instead of silently truncating or
  emitting nonsensical IPv6 prefixes (the C version accepts some of these).
* A successful BMC response without its mandatory revision byte fails instead
  of attempting a negative-length `memcpy`. Short replies **with** a revision
  byte still zero-fill the missing parameter data, as in C. The Zig unit test
  covers both cases and rejects oversized response lengths.
* Dynamic OEM Get/Set validate the selector offset and request/response
  buffer capacities rather than overflowing their fixed-size wire buffers.

Valid C and Zig requests are golden-tested for stdout, stderr, exit status
and byte-for-byte IPMI wire traffic.
