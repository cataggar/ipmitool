# Dell OEM command port

`zig build -Dzig-modules=delloem` replaces `lib/ipmi_delloem.c` with
`src/zig/cmd/delloem.zig` and its six command-family modules. The Zig module
exports `ipmi_delloem_main`, `ipmi_lcd_get_platform_model_name`, and the data
symbols supplied by the C translation unit. The C bridge retains the IPMI
interface vtable, libc output formatting, `ipmi_sdr_find_sdr_byid`,
`ipmi_sdr_get_sensor_thresholds`, `sdr_convert_sensor_reading`, and timestamp
formatting. The Dell source includes SEL and FRU headers but makes **no**
direct calls to SEL or FRU helpers; its power-consumption path depends on SDR
lookup and sensor threshold conversion. SDR records remain owned by the SDR
module; Dell does not free or retain the returned pointers.

The golden suite's `delloem_` cases cover the original C oracle and Zig
replacement with recorded request bytes, output, and exit codes. 12g/iDRAC7,
11g/iDRAC6, and legacy/10g responses exercise LCD configuration and fragmented
strings, LAN selection and active NIC, fragmented system LOM MAC and virtual or
LAN fallback MAC, all power subcommands including full SDR/sensor reads, drive
mapping/LED state, and vFlash SD-card queries. `IPMI_DUMMY_EMULATE_OPEN=1`
identifies the already-connected dummy socket as `open` for vFlash fixtures;
no local IPMI device is opened. The C oracle initializes request fields and
padding that were previously indeterminate, so its recorded request log is
stable across processes and platforms.
The `delloem_` filter runs 123 Dell command cases plus three registry/MC cases
from the broader suite, 126 cases per binary. The
`delloem_lan_invalid_bond_numeric` snapshot comes from the default C oracle:
the malformed iDRAC NIC response prints both promoted `%d` arguments as
`(6) (255)`. It checks stderr and request bytes without a new normalizer.

All seven Dell command-family files use the shared `util/log.zig` typed
`print` path for their original C `printf` formats and argument widths.
When `log` is selected in the same `exports.zig` archive, they share the
selected logger's state; otherwise the wrapper calls C `lprintf`. The few
conditional formats choose only literal strings with the same argument
signature in every arm. No direct `lperror` call was present.

Successful responses preserve C's requests, stdout, stderr, and exit status.
Nine adversarial cases have both `<case>.snap` (original C) and
`<case>.zig.snap` (explicit safety result). Invoke `--zig-deviations` with the
Zig binary; the build does this automatically when `delloem` is selected.

* `delloem_mac_short`, `delloem_lan_short`, `delloem_power_budget_short`,
  `delloem_power_history_short`, `delloem_power_sensor_short`, and
  `delloem_power_status_short`: reject truncated BMC replies instead of
  consuming zero-filled data or indexing past a reply.
* `delloem_setled_short_map`: reject a reply without the bay/slot mapping
  instead of sending a set request with stale or nonexistent mapping bytes.
* `delloem_setled_out_of_range`: reject bus > 255, device > 31, or function >
  7 rather than truncating the PCI BDF in the mapping request.
* `delloem_vflash_short`: reject a truncated SD-card record rather than
  printing stale bytes from earlier responses as card properties.

Further length checks guard LCD, power-monitor, MAC address, and sensor
responses. LOM fragment count is bounded to the eight-entry C array; LCD
strings are bounded to 62 bytes; power histories and caps are decoded with
explicit little-endian loads. When a setting produced uninitialized trailing
request bytes in C, the oracle now initializes those bytes to zero and Zig
sends the same zeroed payload.

Run focused validation without optional host development libraries:

```sh
zig build test-delloem -Dipmishell=false -Dopenssl=false \
  -Dintf-lanplus=false -Dinternal-md5=true
zig build test-golden -Dipmishell=false -Dopenssl=false \
  -Dintf-lanplus=false -Dinternal-md5=true -Dzig-modules=delloem \
  -- --filter delloem_
```
