# Dropped interface plugins

Part of the Phase 4 transport work in issue #10.

Five of upstream's twelve interface plugins are **removed from this fork**
rather than ported to Zig:

| plugin | LOC | upstream default | why it is gone |
| --- | --- | --- | --- |
| `imb` | 1,536 | on for Linux | targets Intel's out-of-tree IMB driver (`/dev/imb`), which no current distribution ships. 1,404 of the 1,536 lines are a driver shim with no test path. |
| `lipmi` | 129 | off | Solaris 9 x86 only; needs `<sys/lipmi/lipmi_intf.h>`. |
| `bmc` | 352 | off | Solaris 10 x86 only; needs `<sys/stropts.h>`. |
| `free` | 318 | off (auto) | needs `libfreeipmi`. |
| `dbus` | 241 | off | needs `libsystemd`. |

## Why they were not ported

The migration's standard of evidence for a transport is
[`transport-fixtures.md`](transport-fixtures.md): a byte-level transcript of
every datagram, independently validated by a model BMC. Four of the five
plugins do not compile in CI or in the maintainer's environment at all, so a
port would be code that is never built, never run and never checked — the
worst possible outcome for a rewrite whose whole premise is that behaviour is
pinned before it is changed.

`imb` does compile, but it is a local device `ioctl` interface: there is no
datagram to capture, so it could never meet the standard that `lan` and
`lanplus` set. The same is true of `lipmi`, `bmc`, `free` and `dbus`. The
only interfaces of that shape that are kept are `open` (the Linux OpenIPMI
driver, which is testable against a model driver and is still the default
interface) and `usb`/`serial`, which are in scope for later steps.

## What changed

* `src/plugins/{imb,lipmi,bmc,free,dbus}/` deleted.
* `src/plugins/ipmi_intf.c`: the five `extern struct ipmi_intf` declarations
  and their `ipmi_intf_table[]` entries.
* `configure.ac`: the `--enable-intf-{imb,lipmi,bmc,free,dbus}` blocks, the
  `libfreeipmi` and `libsystemd` probes, the per-host defaults, the
  `AC_CONFIG_FILES` entries and the configuration summary lines.
* `src/plugins/Makefile.am`: `SUBDIRS` and `DIST_SUBDIRS`.
* `build.zig`: the five `plugins` entries and their `config.h` flags,
  including the `IPMI_INTF_FREE_0_*` ABI variants.
* `README.md`: the `-Dintf-*` table and the sample `-h` output.
* `doc/ipmitool.1.in`: the `lipmi`, `imb` and `free` interface sections.

## The `-h` baseline moved

`imb`'s upstream default is on for Linux, so it appeared in `ipmitool -h`.
Byte parity of `-h` against the autotools oracle has been a load-bearing
invariant for the whole migration, so this is called out explicitly rather
than absorbed.

Before:

```
Interfaces:
	open          Linux OpenIPMI Interface [default]
	imb           Intel IMB Interface
	lan           IPMI v1.5 LAN Interface
	lanplus       IPMI v2.0 RMCP+ LAN Interface
	serial-terminal  Serial Interface, Terminal Mode
	serial-basic  Serial Interface, Basic Mode
	dummy         Linux DummyIPMI Interface
```

After — one line removed, nothing else:

```
Interfaces:
	open          Linux OpenIPMI Interface [default]
	lan           IPMI v1.5 LAN Interface
	lanplus       IPMI v2.0 RMCP+ LAN Interface
	serial-terminal  Serial Interface, Terminal Mode
	serial-basic  Serial Interface, Basic Mode
	dummy         Linux DummyIPMI Interface
```

Five golden snapshots embed the usage text and each lost exactly that one
line: `global_usage`, `global_bad_option`, `global_missing_option_arg`,
`chassis_bootmbox_get_block_neg` and `chassis_identify_negative`. They were
edited by hand, one line each, rather than regenerated — see
[`baseline-oracle.md`](baseline-oracle.md).

**From this commit onward the autotools oracle comparison is against the new
baseline above.** Both build systems changed together, so `zig build` and
`./configure && make` still produce identical `-h` output; what changed is
the value both of them produce.
