# Baseline oracle (Phase 0)

The **oracle** is a reference build of the unmodified autotools C ipmitool.
Every stage of the incremental Zig rewrite (tracking issue #2) is diffed
against it: the Zig build must produce byte-identical stdout/stderr and the
same exit codes for the same inputs. The golden test harness (issue #4) drives
both binaries side by side over the `dummy` interface, so the oracle must be
regenerable on demand and its feature set must be recorded exactly.

Build it with:

```sh
scripts/build-oracle.sh
```

## What the script does

`scripts/build-oracle.sh`

1. checks for every required tool and header and prints an install hint for
   anything that is missing (`--check` runs only this step),
2. runs `./bootstrap`, `./configure <flags>`, `make -j$(nproc)`,
3. copies `src/ipmitool`, `src/ipmievd` and the generated `config.h` into the
   oracle directory together with metadata and the build logs,
4. cleans the build tree again so the checkout is left as it was found
   (`--keep-build` skips this).

It is idempotent — re-running it overwrites the oracle in place. It never
stages anything in git and only ever deletes *untracked* autotools output under
`lib/`, `src/`, `include/`, `doc/`, `contrib/`, `control/` and the repository
root, so unrelated work in the same checkout is safe.

### Options and environment variables

| Option | Environment variable | Default |
| --- | --- | --- |
| `-o`, `--out DIR` | `ORACLE_DIR` | `<repo>/../ipmitool-oracle` |
| `-r`, `--ref REF` | `ORACLE_REF` | current working tree |
| `-j`, `--jobs N` | `ORACLE_JOBS` | `nproc` |
| `--keep-build` | `ORACLE_KEEP_BUILD=1` | clean the tree |
| `--check` | – | full build |
| – | `ORACLE_SRC_DIR` | `$ORACLE_DIR/src` (only with a ref) |
| – | `ORACLE_CONFIGURE_FLAGS` | see below (replaces the defaults) |
| – | `ORACLE_EXTRA_CONFIGURE_FLAGS` | empty (appended to the defaults) |

### Output layout

```
$ORACLE_DIR/
├── ipmitool          # the oracle binary
├── ipmievd
├── config.h          # resolved feature set as the compiler saw it
├── ipmitool-V.txt    # `ipmitool -V`
├── ipmitool-h.txt    # `ipmitool -h` (interface + command list)
├── ipmievd-V.txt
├── metadata.txt      # human readable provenance
├── metadata.json     # same data for the test harness
├── SHA256SUMS
└── logs/{bootstrap,configure,make}.log
```

## Dependencies

| Component | Purpose | Required |
| --- | --- | --- |
| `gcc`, `make`, `git`, `sed`, `awk`, `find` | build | yes |
| `autoconf`, `automake`, `libtool` | `./bootstrap` | yes |
| `pkg-config` | readline / libcrypto detection | yes |
| OpenSSL headers (`openssl/evp.h`) | `lanplus`, MD5/SHA-256 | yes for the default flags |
| readline headers (`readline/readline.h`) | `--enable-ipmishell` | yes for the default flags |
| `libfreeipmi`, `libsystemd`, `sys/lipmi/lipmi_intf.h` | `free`, `dbus`, `lipmi` interfaces | no, all optional |

Install:

```sh
# Debian / Ubuntu
sudo apt-get install -y build-essential autoconf automake libtool \
    pkg-config libssl-dev libreadline-dev

# Fedora / RHEL
sudo dnf install -y gcc make autoconf automake libtool \
    pkgconf-pkg-config openssl-devel readline-devel

# Azure Linux 3.0 (the environment this baseline was recorded on)
sudo dnf install -y build-essential autoconf automake libtool \
    pkg-config openssl-devel readline-devel
```

On the recording host only `autoconf`, `automake` and `readline-devel` had to
be added; `gcc`, `make`, `libtool`, `pkg-config` and `openssl-devel` were
already present.

## Configure flags

```
--enable-intf-lan --enable-intf-lanplus --enable-intf-open \
--enable-intf-serial --enable-intf-dummy --enable-ipmishell \
--disable-registry-download
```

Why these:

* `--enable-intf-dummy` — **not** enabled by `configure.ac` by default
  (`configure.ac` sets `xenable_intf_dummy=no`). The golden test harness
  (issue #4) drives the `dummy` interface, so the oracle must enable it
  explicitly. The script always passes this flag.
* `--enable-intf-lan`, `--enable-intf-open`, `--enable-intf-serial` — these are
  already the defaults on Linux; passing them explicitly pins the feature set
  so a change in `configure.ac` defaults cannot silently move the oracle.
* `--enable-intf-lanplus` — default is `auto` (enabled when libcrypto provides
  `EVP_aes_128_cbc`); pinned explicitly, and the build fails loudly if OpenSSL
  is missing rather than silently dropping IPMI v2.0.
* `--enable-ipmishell` — needs readline. Pinned so the `shell`/`exec` commands
  are part of the oracle surface.
* `--disable-registry-download` — the IANA PEN registry is only fetched during
  `make install`; disabling it keeps the oracle build hermetic (no network).
* `--enable-internal-md5` is **not** used: the baseline uses OpenSSL's MD5, the
  same choice distributions make. Set
  `ORACLE_EXTRA_CONFIGURE_FLAGS=--enable-internal-md5` to build the internal
  variant instead.

## Recorded baseline

Source commit `3ca7703e2fa4c1ed78bab713728ca375abd64cf5`
(`IPMITOOL_1_8_19-61-g3ca7703`), host `aarch64-unknown-linux-gnu`
(Azure Linux 3.0, kernel 6.6.139.1-1.azl3).

| Tool | Version |
| --- | --- |
| gcc | 13.2.0 |
| make | GNU Make 4.4.1 |
| autoconf | 2.72 |
| automake | 1.16.5 |
| libtool | 2.4.7 |
| pkg-config | 2.0.2 |
| OpenSSL | 3.3.7 (libcrypto 3.3.7) |
| readline | 8.2 |

### Resolved feature set

| Feature | Result | Why |
| --- | --- | --- |
| `intf-lan` | **yes** | requested |
| `intf-lanplus` | **yes** | requested, `EVP_aes_128_cbc` found in libcrypto |
| `intf-open` | **yes** | requested, `linux/ipmi.h` present; default interface |
| `intf-serial` | **yes** | requested (`serial-basic` and `serial-terminal`) |
| `intf-dummy` | **yes** | requested (needed by the golden test harness) |
| `intf-imb` | **yes** | `configure.ac` default on Linux (`xenable_intf_imb=yes`) |
| `intf-usb` | no | `configure.ac` default is `no` on Linux (only Hurd sets it); not requested |
| `intf-free` | no | `libfreeipmi` is not installed (`ipmi_open_inband`/`ipmi_ctx_open_inband` not found) |
| `intf-dbus` | no | default `no`, and `sd_bus_default` was not found (no `libsystemd` development files) |
| `intf-bmc` | no | Solaris/BSD-only interface |
| `intf-lipmi` | no | Solaris 9 x86 only; `sys/lipmi/lipmi_intf.h` not found |
| `ipmishell` | **yes** | requested, readline 8.2 found via pkg-config |
| `ipmievd` | **yes** | always built |
| registry download | no | disabled on purpose (hermetic build) |
| internal MD5 | no | OpenSSL MD5 is used instead |

OpenSSL algorithm probes (`logs/configure.log`):

```
checking for EVP_aes_128_cbc in -lcrypto... yes   -> lanplus / AES-128-CBC
checking for EVP_sha256 in -lcrypto... yes        -> HAVE_CRYPTO_SHA256
checking for MD5_Init in -lcrypto... yes          -> HAVE_CRYPTO_MD5
checking for MD2_Init in -lcrypto... no           -> HAVE_CRYPTO_MD2 undefined
```

MD2 is unavailable because OpenSSL 3.x no longer ships the legacy MD2
implementation. Consequently `ipmitool -A MD2` cannot negotiate MD2
authentication in this oracle. Any Zig port must reproduce the *same*
behaviour when compared against this oracle; a build with MD2 present is a
different oracle and must be recorded separately.

Two more resolved values worth carrying into the port, both from `config.h`:

* `ENABLE_INTF_OPEN_DUAL_BRIDGE` is **not** defined — configure reported
  `checking for OpenIPMI dual bridge support... no` on this host, so the
  `open` interface has no dual-bridge support in the oracle.
* `HAVE_PRAGMA_PACK` is defined, i.e. the packed-bitfield probe in
  `configure.ac` selected `#pragma pack` instead of
  `__attribute__((packed))`.

### `ipmitool -V`

```
ipmitool version 1.8.19.61.g3ca7703
```

`ipmievd -V`:

```
ipmievd version 1.8.19.61.g3ca7703
```

### Interfaces reported by `ipmitool -h`

> **Superseded.** This section records the *upstream* baseline as it was
> measured, and is left unedited on purpose. `imb`, `lipmi`, `bmc`, `free` and
> `dbus` were removed from this fork under issue #10, so the current `-h`
> baseline has no `imb` line. See
> [`dropped-transports.md`](dropped-transports.md).

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

The full `-h` output, including the command list, is archived as
`ipmitool-h.txt` next to the binaries. Stream behaviour matters for the golden
harness: `-V` is printed on **stdout**, `-h` is printed on **stderr**, and both
exit with status `0`.

## Rebuilding the oracle from an arbitrary commit

```sh
# current working tree
scripts/build-oracle.sh

# a specific commit, tag or branch, built in a scratch clone
scripts/build-oracle.sh --ref IPMITOOL_1_8_19 --out ~/oracles/1.8.19

# upstream commit that is not in this fork yet
git remote add upstream https://codeberg.org/IPMITool/ipmitool.git
git fetch upstream
scripts/build-oracle.sh --ref upstream/master --out ~/oracles/upstream
```

With `--ref` the script clones the repository into `$ORACLE_DIR/src`
(overridable with `ORACLE_SRC_DIR`), checks the ref out detached, and runs
`git clean -xdfq` **inside that scratch clone only**. The primary working tree
is never modified. The scratch clone is kept so that incremental rebuilds are
cheap; delete it manually when you no longer need it.

Provenance for every oracle is written to `metadata.txt` / `metadata.json`
(commit SHA, `git describe`, dirty flag, configure flags, host triplet, tool
versions, resolved features and the binary SHA-256 sums), so a golden test
failure can always be attributed to a specific baseline.

## Reproducibility notes

* Two consecutive clean builds of the same commit on the same host produced
  byte-identical binaries (identical SHA-256), so the sums in `SHA256SUMS` are
  a usable integrity check on one host.
* Binaries are **not** reproducible across hosts: compiler version, OpenSSL
  version and paths are baked in. Compare *behaviour* (stdout/stderr/exit
  code), not binary hashes, across machines — that is what the golden harness
  does.
* The oracle binaries are deliberately **not** committed to the repository;
  they are build output. Archive them next to the checkout, in CI artifacts,
  or in a release asset.
