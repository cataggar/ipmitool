//! Zig build definition for ipmitool.
//!
//! This replaces autotools as the primary build system while still compiling
//! the existing C sources with `zig cc`.  It is a translation of `configure.ac`
//! plus the `Makefile.am` files; those remain in the tree as a cross-check
//! until the C sources are gone.
//!
//! The source inventory below is kept in named, per-component data structures
//! on purpose: the incremental Zig migration replaces translation units one at
//! a time, so every group of C files must stay individually addressable.

const std = @import("std");

/// Base version, mirroring `AC_INIT([ipmitool],[1.8.19...])` in configure.ac.
/// The suffix produced by `./csv-revision` is appended at configure time.
const base_version = "1.8.19";

/// `IANA_PEN` from the top level Makefile.am.
const iana_pen_url = "https://www.iana.org/assignments/enterprise-numbers.txt";

/// Warning flags configure.ac unconditionally appends to CFLAGS.
const base_cflags = [_][]const u8{
    "-std=gnu11",
    "-Wall",
    "-Wextra",
    "-pedantic",
    "-Wformat",
    "-Wformat-nonliteral",
};

/// Extra flags for `-Dbuildcheck`, mirroring `--enable-buildcheck`.
const buildcheck_cflags = [_][]const u8{
    "-Werror",
    "-Wpointer-arith",
    "-Wstrict-prototypes",
};

// ---------------------------------------------------------------------------
// Source inventory
//
// Each entry corresponds to one `*_SOURCES` variable in a `Makefile.am`.
// Phase 2 of the migration (issue #7) swaps individual entries here for Zig
// implementations, so keep the lists narrow and named.
// ---------------------------------------------------------------------------

/// A set of C translation units rooted at a single directory.
const CSourceSet = struct {
    /// Directory relative to the build root.
    dir: []const u8,
    /// File names relative to `dir`.
    files: []const []const u8,
};

/// `lib/Makefile.am`: `libipmitool_la_SOURCES`.
const lib_sources: CSourceSet = .{
    .dir = "lib",
    .files = &.{
        "helper.c",       "ipmi_sdr.c",        "ipmi_sel.c",        "ipmi_sol.c",
        "ipmi_pef.c",     "ipmi_lanp.c",       "ipmi_fru.c",        "ipmi_chassis.c",
        "ipmi_mc.c",      "log.c",             "dimm_spd.c",        "ipmi_sensor.c",
        "ipmi_channel.c", "ipmi_event.c",      "ipmi_session.c",    "ipmi_strings.c",
        "ipmi_user.c",    "ipmi_raw.c",        "ipmi_oem.c",        "ipmi_isol.c",
        "ipmi_sunoem.c",  "ipmi_fwum.c",       "ipmi_picmg.c",      "ipmi_main.c",
        "ipmi_tsol.c",    "ipmi_firewall.c",   "ipmi_kontronoem.c", "ipmi_hpmfwupg.c",
        "ipmi_sdradd.c",  "ipmi_ekanalyzer.c", "ipmi_gendev.c",     "ipmi_ime.c",
        "ipmi_delloem.c", "ipmi_dcmi.c",       "hpm2.c",            "ipmi_vita.c",
        "ipmi_lanp6.c",   "ipmi_cfgp.c",       "ipmi_quantaoem.c",  "ipmi_time.c",
    },
};

/// `src/plugins/Makefile.am`: `libintf_la_SOURCES` (the interface dispatcher).
const intf_sources: CSourceSet = .{
    .dir = "src/plugins",
    .files = &.{"ipmi_intf.c"},
};

/// `src/Makefile.am`: `ipmitool_SOURCES`.
const ipmitool_sources: CSourceSet = .{
    .dir = "src",
    .files = &.{ "ipmitool.c", "ipmishell.c" },
};

/// `src/Makefile.am`: `ipmievd_SOURCES`.
const ipmievd_sources: CSourceSet = .{
    .dir = "src",
    .files = &.{"ipmievd.c"},
};

// ---------------------------------------------------------------------------
// Zig module registry
//
// Phase 2 of the migration (issue #7).  Every entry maps one `-Dzig-modules`
// name to the C translation unit it replaces; selecting a name drops that `.c`
// from the compile and links `src/zig/exports.zig` instead, which `@export`s
// the same C symbols. The `evd` executable is the exception: its Zig file is
// the executable root, not a member of the shared replacement archive.
//
// See doc/zig-migration/interop-seams.md.
// ---------------------------------------------------------------------------

/// One Zig port and the C translation units it replaces.
const ZigModule = struct {
    /// Name used in `-Dzig-modules=<name>`.
    name: []const u8,
    /// C translation unit it replaces, relative to the build root.
    replaces: []const u8,
    /// Further C translation units the same Zig module replaces, relative to
    /// the build root. `sdr` replaces a second command source, while `cli`
    /// replaces both the shared parser and the ipmitool-specific entrypoint.
    also_replaces: []const []const u8 = &.{},
    /// Zig implementation, for documentation and `zig build --help`.
    implementation: []const u8,
    /// C files the Zig implementation needs alongside it, relative to the
    /// build root.  Only `lib/log.c` has one: Zig 0.16 cannot define a C
    /// variadic function on aarch64, so `lprintf()`/`lperror()` keep a
    /// `va_start` trampoline.  See doc/zig-migration/varargs-trampoline.md.
    c_shims: []const []const u8 = &.{},
};

const zig_modules = [_]ZigModule{
    .{
        .name = "tsol",
        .replaces = "lib/ipmi_tsol.c",
        .implementation = "src/zig/cmd/tsol.zig",
    },
    .{
        .name = "lanp6",
        .replaces = "lib/ipmi_lanp6.c",
        .implementation = "src/zig/cmd/lanp6.zig",
    },
    .{
        .name = "evd",
        .replaces = "src/ipmievd.c",
        .implementation = "src/zig/front/ipmievd.zig",
    },
    .{
        .name = "gendev",
        .replaces = "lib/ipmi_gendev.c",
        .implementation = "src/zig/cmd/gendev.zig",
    },
    .{
        .name = "cli",
        .replaces = "lib/ipmi_main.c",
        .also_replaces = &.{"src/ipmitool.c"},
        .implementation = "src/zig/cli/main.zig and src/zig/cli/tool.zig",
    },
    .{
        .name = "delloem",
        .replaces = "lib/ipmi_delloem.c",
        .implementation = "src/zig/cmd/delloem.zig",
    },
    .{
        .name = "oem",
        .replaces = "lib/ipmi_oem.c",
        .implementation = "src/zig/cmd/oem.zig",
    },
    .{
        .name = "sunoem",
        .replaces = "lib/ipmi_sunoem.c",
        .implementation = "src/zig/cmd/sunoem.zig",
    },
    .{
        .name = "channel",
        .replaces = "lib/ipmi_channel.c",
        .implementation = "src/zig/cmd/channel.zig",
    },
    .{
        .name = "lanp",
        .replaces = "lib/ipmi_lanp.c",
        .implementation = "src/zig/cmd/lanp.zig",
    },
    .{
        .name = "user",
        .replaces = "lib/ipmi_user.c",
        .implementation = "src/zig/cmd/user.zig",
    },
    .{
        .name = "strings",
        .replaces = "lib/ipmi_strings.c",
        .implementation = "src/zig/util/strings.zig",
    },
    .{
        .name = "log",
        .replaces = "lib/log.c",
        .implementation = "src/zig/util/log.zig",
        .c_shims = &.{"src/zig/util/log_varargs.c"},
    },
    .{
        .name = "helper",
        .replaces = "lib/helper.c",
        .implementation = "src/zig/util/helper.zig",
    },
    .{
        .name = "time",
        .replaces = "lib/ipmi_time.c",
        .implementation = "src/zig/util/time.zig",
    },
    .{
        .name = "cfgp",
        .replaces = "lib/ipmi_cfgp.c",
        .implementation = "src/zig/cmd/cfgp.zig",
    },
    .{
        .name = "session",
        .replaces = "lib/ipmi_session.c",
        .implementation = "src/zig/cmd/session.zig",
    },
    .{
        .name = "hpm2",
        .replaces = "lib/hpm2.c",
        .implementation = "src/zig/cmd/hpm2.zig",
    },
    .{
        .name = "md5",
        .replaces = "src/plugins/lan/md5.c",
        .implementation = "src/zig/crypto/md5.zig",
    },
    .{
        .name = "auth",
        .replaces = "src/plugins/lan/auth.c",
        .implementation = "src/zig/crypto/auth.zig",
    },
    .{
        .name = "lanplus-crypt-impl",
        .replaces = "src/plugins/lanplus/lanplus_crypt_impl.c",
        .implementation = "src/zig/crypto/lanplus_crypt_impl.zig",
    },
    .{
        .name = "lanplus-crypt",
        .replaces = "src/plugins/lanplus/lanplus_crypt.c",
        .implementation = "src/zig/crypto/lanplus_crypt.zig",
    },
    .{
        .name = "raw",
        .replaces = "lib/ipmi_raw.c",
        .implementation = "src/zig/cmd/raw.zig",
    },
    .{
        .name = "mc",
        .replaces = "lib/ipmi_mc.c",
        .implementation = "src/zig/cmd/mc.zig",
    },
    .{
        .name = "chassis",
        .replaces = "lib/ipmi_chassis.c",
        .implementation = "src/zig/cmd/chassis.zig",
    },
    .{
        .name = "event",
        .replaces = "lib/ipmi_event.c",
        .implementation = "src/zig/cmd/event.zig",
    },
    .{
        .name = "picmg",
        .replaces = "lib/ipmi_picmg.c",
        .implementation = "src/zig/cmd/picmg.zig",
    },
    .{
        .name = "firewall",
        .replaces = "lib/ipmi_firewall.c",
        .implementation = "src/zig/cmd/firewall.zig",
    },
    .{
        .name = "sensor",
        .replaces = "lib/ipmi_sensor.c",
        .implementation = "src/zig/cmd/sensor.zig",
    },
    .{
        .name = "fwum",
        .replaces = "lib/ipmi_fwum.c",
        .implementation = "src/zig/cmd/fwum.zig",
    },
    .{
        .name = "sel",
        .replaces = "lib/ipmi_sel.c",
        .implementation = "src/zig/cmd/sel.zig",
    },
    .{
        .name = "sdr",
        .replaces = "lib/ipmi_sdr.c",
        .also_replaces = &.{"lib/ipmi_sdradd.c"},
        .implementation = "src/zig/cmd/sdr.zig",
    },
    .{
        .name = "quantaoem",
        .replaces = "lib/ipmi_quantaoem.c",
        .implementation = "src/zig/cmd/quantaoem.zig",
    },
    .{
        .name = "kontronoem",
        .replaces = "lib/ipmi_kontronoem.c",
        .implementation = "src/zig/cmd/kontronoem.zig",
    },
    .{
        .name = "sol",
        .replaces = "lib/ipmi_sol.c",
        .implementation = "src/zig/cmd/sol.zig",
    },
    .{
        .name = "isol",
        .replaces = "lib/ipmi_isol.c",
        .implementation = "src/zig/cmd/isol.zig",
    },
    .{
        .name = "vita",
        .replaces = "lib/ipmi_vita.c",
        .implementation = "src/zig/cmd/vita.zig",
    },
    .{
        .name = "dcmi",
        .replaces = "lib/ipmi_dcmi.c",
        .implementation = "src/zig/cmd/dcmi.zig",
    },
    .{
        .name = "fru",
        .replaces = "lib/ipmi_fru.c",
        .implementation = "src/zig/cmd/fru.zig",
    },
    .{
        .name = "dimm-spd",
        .replaces = "lib/dimm_spd.c",
        .implementation = "src/zig/cmd/dimm_spd.zig",
    },
    .{
        .name = "hpmfwupg",
        .replaces = "lib/ipmi_hpmfwupg.c",
        .implementation = "src/zig/cmd/hpmfwupg.zig",
    },
    .{
        .name = "ime",
        .replaces = "lib/ipmi_ime.c",
        .implementation = "src/zig/cmd/ime.zig",
    },
    .{
        .name = "ekanalyzer",
        .replaces = "lib/ipmi_ekanalyzer.c",
        .implementation = "src/zig/cmd/ekanalyzer.zig",
    },
    .{
        .name = "pef",
        .replaces = "lib/ipmi_pef.c",
        .implementation = "src/zig/cmd/pef.zig",
    },
    .{
        .name = "intf",
        .replaces = "src/plugins/ipmi_intf.c",
        .implementation = "src/zig/intf/registry.zig",
    },
    .{
        .name = "dummy",
        .replaces = "src/plugins/dummy/dummy.c",
        .implementation = "src/zig/intf/dummy.zig",
    },
    .{
        .name = "open",
        .replaces = "src/plugins/open/open.c",
        .implementation = "src/zig/intf/open.zig",
    },
    .{
        .name = "lan",
        .replaces = "src/plugins/lan/lan.c",
        .implementation = "src/zig/intf/lan.zig",
    },
    .{
        .name = "lanplus",
        .replaces = "src/plugins/lanplus/lanplus.c",
        .implementation = "src/zig/intf/lanplus.zig",
    },
    .{
        .name = "lanplus-strings",
        .replaces = "src/plugins/lanplus/lanplus_strings.c",
        .implementation = "src/zig/intf/lanplus_strings.zig",
    },
    .{
        .name = "lanplus-dump",
        .replaces = "src/plugins/lanplus/lanplus_dump.c",
        .implementation = "src/zig/intf/lanplus_dump.zig",
    },
    .{
        .name = "serial-basic",
        .replaces = "src/plugins/serial/serial_basic.c",
        .implementation = "src/zig/intf/serial_basic.zig",
    },
    .{
        .name = "serial-terminal",
        .replaces = "src/plugins/serial/serial_terminal.c",
        .implementation = "src/zig/intf/serial_terminal.zig",
    },
    .{
        .name = "usb",
        .replaces = "src/plugins/usb/usb.c",
        .implementation = "src/zig/intf/usb.zig",
    },
    .{
        .name = "ipmishell",
        .replaces = "src/ipmishell.c",
        .implementation = "src/zig/frontend/ipmishell.zig",
    },
};

/// Root of the Zig source tree.
const zig_root = "src/zig";

// ---------------------------------------------------------------------------
// libcrypto inventory (issue #9)
//
// OpenSSL is the last external dependency the migration removes.  Keeping the
// two lists below next to `zig_modules` means the link line and the parity
// fixtures both follow automatically as the ports land.
// ---------------------------------------------------------------------------

/// C translation units that call into libcrypto.  `-lcrypto` goes on the link
/// line only while at least one of them is still being compiled, so selecting
/// the Zig replacements drops the dependency by itself.
const libcrypto_c_sources = [_][]const u8{
    // EVP_aes_128_cbc, HMAC, RAND_bytes, RAND_load_file.
    "src/plugins/lanplus/lanplus_crypt_impl.c",
    // MD5_Init/Update/Final, but only when HAVE_CRYPTO_MD5 is defined.
    "src/plugins/lan/auth.c",
};

/// Everything `tests/crypto/gen_vectors.c` links to dump the parity fixtures:
/// the libcrypto users plus the two pure-C files layered on top of them.
const crypto_vector_sources = [_][]const u8{
    "src/plugins/lan/md5.c",
    "src/plugins/lan/auth.c",
    "src/plugins/lanplus/lanplus_crypt_impl.c",
    "src/plugins/lanplus/lanplus_crypt.c",
};
/// Umbrella header translated into the `ipmi_c` module.
const zig_bridge_header = zig_root ++ "/ipmi_c.h";

/// How the default value of an `-Dintf-*` option is computed.
const DefaultPolicy = enum {
    /// Enabled everywhere.
    on,
    /// Disabled unless explicitly requested.
    off,
    /// Enabled only when targeting Linux.
    linux_only,
};

/// One IPMI transport plugin, i.e. one `src/plugins/<dir>/Makefile.am` plus the
/// matching `AC_ARG_ENABLE([intf-...])` block in configure.ac.
const Plugin = struct {
    /// Name used for the `-Dintf-<name>` build option.
    name: []const u8,
    /// config.h macro that gates the plugin in `src/plugins/ipmi_intf.c`.
    macro: []const u8,
    sources: CSourceSet,
    default: DefaultPolicy,
    /// System libraries this plugin needs on top of libc.
    system_libs: []const []const u8 = &.{},
    /// `zig build --help` text.
    help: []const u8,
};

/// Every plugin known to the tree, in the order `ipmi_intf_table` lists them.
const plugins = [_]Plugin{
    .{
        .name = "open",
        .macro = "IPMI_INTF_OPEN",
        .sources = .{ .dir = "src/plugins/open", .files = &.{"open.c"} },
        .default = .linux_only,
        .help = "Linux OpenIPMI kernel driver interface",
    },
    .{
        .name = "lan",
        .macro = "IPMI_INTF_LAN",
        .sources = .{
            .dir = "src/plugins/lan",
            .files = &.{ "lan.c", "auth.c", "md5.c" },
        },
        .default = .on,
        .help = "IPMIv1.5 LAN interface",
    },
    .{
        .name = "lanplus",
        .macro = "IPMI_INTF_LANPLUS",
        .sources = .{
            .dir = "src/plugins/lanplus",
            .files = &.{
                "lanplus.c",
                "lanplus_strings.c",
                "lanplus_crypt.c",
                "lanplus_dump.c",
                "lanplus_crypt_impl.c",
            },
        },
        .default = .on,
        .system_libs = &.{"crypto"},
        .help = "IPMIv2.0 RMCP+ LAN interface (requires libcrypto)",
    },
    .{
        .name = "serial",
        .macro = "IPMI_INTF_SERIAL",
        .sources = .{
            .dir = "src/plugins/serial",
            .files = &.{ "serial_terminal.c", "serial_basic.c" },
        },
        .default = .on,
        .help = "direct Serial Basic/Terminal mode interface",
    },
    .{
        .name = "dummy",
        .macro = "IPMI_INTF_DUMMY",
        .sources = .{ .dir = "src/plugins/dummy", .files = &.{"dummy.c"} },
        .default = .on,
        .help = "Dummy (test) interface used by the golden test harness",
    },
    .{
        .name = "usb",
        .macro = "IPMI_INTF_USB",
        .sources = .{ .dir = "src/plugins/usb", .files = &.{"usb.c"} },
        .default = .off,
        .help = "AMI USB interface",
    },
};

/// `contrib/Makefile.am`: `dist_pkgdata_DATA`, installed into `share/ipmitool`.
const contrib_data = [_][]const u8{"oem_ibm_sel_map"};

/// `contrib/Makefile.am`: `EXTRA_DIST` helper scripts and unit files.
const contrib_scripts = [_][]const u8{
    "README",
    "bmc-snmp-proxy",
    "bmc-snmp-proxy.service",
    "bmc-snmp-proxy.sysconf",
    "bmclanconf",
    "collect_data.sh",
    "create_rrds.sh",
    "create_webpage.sh",
    "create_webpage_compact.sh",
    "exchange-bmc-os-info.init.redhat",
    "exchange-bmc-os-info.service.redhat",
    "exchange-bmc-os-info.sysconf",
    "ipmi.init.basic",
    "ipmi.init.redhat",
    "ipmievd.init.debian",
    "ipmievd.init.redhat",
    "ipmievd.init.suse",
    "log_bmc.sh",
};

/// Top level `Makefile.am`: `DOCLIST`, installed into `share/doc/ipmitool`.
const doc_files = [_][]const u8{ "README.md", "COPYING", "AUTHORS", "ChangeLog" };

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const is_linux = os == .linux;
    const is_windows = os == .windows;
    const is_bsdish = switch (os) {
        .freebsd, .netbsd, .openbsd, .dragonfly, .macos, .ios, .tvos, .watchos, .illumos => true,
        else => false,
    };

    // -- feature options, mirroring configure.ac ----------------------------

    var enabled: [plugins.len]bool = undefined;
    for (plugins, 0..) |plugin, i| {
        const default = switch (plugin.default) {
            .on => true,
            .off => false,
            .linux_only => is_linux,
        };
        enabled[i] = b.option(
            bool,
            b.fmt("intf-{s}", .{plugin.name}),
            b.fmt("Enable the {s} [default={}]", .{ plugin.help, default }),
        ) orelse default;
    }

    const openssl = b.option(
        bool,
        "openssl",
        "Link libcrypto for SHA256/MD5 and RMCP+ crypto [default=true]",
    ) orelse true;
    const internal_md5 = b.option(
        bool,
        "internal-md5",
        "Use the bundled MD5 implementation instead of libcrypto [default=false]",
    ) orelse false;
    const ipmishell = b.option(
        bool,
        "ipmishell",
        "Enable the interactive IPMI shell [default=true]",
    ) orelse true;
    const readline_libs_opt = b.option(
        []const u8,
        "readline-libs",
        "Comma separated libraries to link for readline, overriding autodetection",
    );
    const all_options = b.option(
        bool,
        "all-options",
        "Enable all command line options (ENABLE_ALL_OPTIONS) [default=true]",
    ) orelse true;
    const file_security = b.option(
        bool,
        "file-security",
        "Extra security checks on files opened for read [default=false]",
    ) orelse false;
    const buildcheck = b.option(
        bool,
        "buildcheck",
        "Add -Werror and stricter warnings for build testing [default=false]",
    ) orelse false;
    const sanitize_c = b.option(
        bool,
        "sanitize-c",
        "Enable the C undefined behaviour sanitizer; off by default so that " ++
            "behaviour matches the autotools/gcc build [default=false]",
    ) orelse false;
    const registry_download = b.option(
        bool,
        "registry-download",
        "Download and install the IANA PEN registry; needs network access [default=false]",
    ) orelse false;

    const zig_modules_opt = b.option(
        []const u8,
        "zig-modules",
        b.fmt(
            "Comma separated modules to build from Zig instead of C; " ++
                "available: all, {s} [default=none]",
            .{comptime zigModuleNames()},
        ),
    );
    const zig_selection = parseZigModules(b, zig_modules_opt);

    const iana_dir = b.option(
        []const u8,
        "iana-dir",
        "Path to the system IANA PEN dictionary [default=<prefix>/share/misc]",
    ) orelse b.getInstallPath(.prefix, "share/misc");
    const iana_user_dir = b.option(
        []const u8,
        "iana-user-dir",
        "Path to the per-user IANA PEN dictionary, relative to $HOME",
    ) orelse ".local/usr/share/misc";

    const version = b.option(
        []const u8,
        "version",
        "Override the version string baked into the binaries",
    ) orelse detectVersion(b);

    // lanplus is the only component that hard-requires AES and the keyed
    // hashes.  It used to get them exclusively from libcrypto; selecting the
    // Zig crypto ports is now an equally good answer, so `-Dopenssl=false` only
    // disables it while the C implementation is still in the build.
    const lanplus_index = pluginIndex("lanplus");
    const lanplus_crypt_in_zig =
        replacedByZig("src/plugins/lanplus/lanplus_crypt_impl.c", zig_selection);
    if (enabled[lanplus_index] and !openssl and !lanplus_crypt_in_zig) {
        std.debug.print(
            "warning: -Dintf-lanplus requires libcrypto; disabling it because -Dopenssl=false\n",
            .{},
        );
        enabled[lanplus_index] = false;
    }

    // Keep the readline dependency only while the C shell is being compiled.
    // The Zig editor uses termios/poll and needs no readline headers or library.
    const readline_libs: []const []const u8 = if (!ipmishell or
        replacedByZig("src/ipmishell.c", zig_selection))
        &.{}
    else
        (if (readline_libs_opt) |list| nonEmpty(splitList(b, list)) else detectReadline(b)) orelse {
            std.debug.print(
                \\error: -Dipmishell is enabled but libreadline was not found.
                \\
                \\  The `shell` and `exec` commands need readline, and the autotools
                \\  baseline is built with --enable-ipmishell, so disabling it silently
                \\  would drop a command that the reference build has.
                \\
                \\  Install the readline development package (readline-devel /
                \\  libreadline-dev), or point the build at it explicitly with
                \\  -Dreadline-libs=readline,tinfo, or build without the shell using
                \\  -Dipmishell=false.
                \\
            , .{});
            std.process.exit(1);
        };

    const default_intf = b.option(
        []const u8,
        "default-intf",
        "Interface used when none is given on the command line [default=open, or lan]",
    ) orelse blk: {
        if (enabled[pluginIndex("open")]) break :blk "open";
        if (enabled[pluginIndex("lan")]) break :blk "lan";
        for (plugins, 0..) |plugin, i| if (enabled[i]) break :blk plugin.name;
        break :blk "lan";
    };
    validateDefaultIntf(b, default_intf, &enabled);

    // -- config.h ------------------------------------------------------------

    const config_h = b.addConfigHeader(.{
        .style = .blank,
        .include_path = "config.h",
    }, .{
        // AC_INIT
        .PACKAGE = "ipmitool",
        .PACKAGE_NAME = "ipmitool",
        .PACKAGE_TARNAME = "ipmitool",
        .PACKAGE_STRING = b.fmt("ipmitool {s}", .{version}),
        .PACKAGE_VERSION = version,
        .PACKAGE_BUGREPORT = "",
        .PACKAGE_URL = "",
        .VERSION = version,

        // AC_C_BIGENDIAN
        .WORDS_BIGENDIAN = flag(target.result.cpu.arch.endian() == .big),

        // AC_CHECK_HEADERS.  Zig ships the libc headers for every supported
        // target, so availability is a pure function of the target triple.
        .STDC_HEADERS = flag(true),
        .HAVE_STDIO_H = flag(true),
        .HAVE_STDLIB_H = flag(true),
        .HAVE_STRING_H = flag(true),
        .HAVE_STRINGS_H = flag(!is_windows),
        .HAVE_INTTYPES_H = flag(true),
        .HAVE_STDINT_H = flag(true),
        .HAVE_UNISTD_H = flag(!is_windows),
        .HAVE_FCNTL_H = flag(true),
        .HAVE_PATHS_H = flag(!is_windows),
        .HAVE_NETDB_H = flag(!is_windows),
        .HAVE_ARPA_INET_H = flag(!is_windows),
        .HAVE_NETINET_IN_H = flag(!is_windows),
        .HAVE_SYS_IOCTL_H = flag(!is_windows),
        .HAVE_SYS_SELECT_H = flag(!is_windows),
        .HAVE_SYS_SOCKET_H = flag(!is_windows),
        .HAVE_SYS_STAT_H = flag(true),
        .HAVE_SYS_TYPES_H = flag(true),
        .HAVE_BYTESWAP_H = flag(is_linux),
        .HAVE_SYS_BYTEORDER_H = flag(os == .illumos),
        .HAVE_SYS_IOCCOM_H = flag(is_bsdish),
        .HAVE_TERMIOS_H = flag(!is_windows),
        .HAVE_SYS_TERMIOS_H = flag(false),
        .HAVE_LINUX_COMPILER_H = flag(false),
        .HAVE_OPENIPMI_H = flag(is_linux),
        .HAVE_FREEBSD_IPMI_H = flag(os == .freebsd or os == .netbsd),

        // AC_CHECK_FUNCS
        .HAVE_ALARM = flag(!is_windows),
        .HAVE_GETADDRINFO = flag(true),
        .HAVE_GETHOSTBYNAME = flag(true),
        .HAVE_GETIFADDRS = flag(!is_windows),
        .HAVE_GETPASSPHRASE = flag(os == .illumos),
        .HAVE_MEMMOVE = flag(true),
        .HAVE_MEMSET = flag(true),
        .HAVE_SELECT = flag(true),
        .HAVE_SOCKET = flag(true),
        .HAVE_STRCHR = flag(true),
        .HAVE_STRDUP = flag(true),
        .HAVE_STRERROR = flag(true),

        // libcrypto capabilities.  OpenSSL 3 no longer provides MD2.
        .HAVE_CRYPTO_SHA256 = flag(openssl),
        .HAVE_CRYPTO_MD5 = flag(openssl and !internal_md5),
        .HAVE_CRYPTO_MD2 = flag(false),

        // Interfaces
        .IPMI_INTF_OPEN = flag(enabled[pluginIndex("open")]),
        .IPMI_INTF_LAN = flag(enabled[pluginIndex("lan")]),
        .IPMI_INTF_LANPLUS = flag(enabled[pluginIndex("lanplus")]),
        .IPMI_INTF_SERIAL = flag(enabled[pluginIndex("serial")]),
        .IPMI_INTF_DUMMY = flag(enabled[pluginIndex("dummy")]),
        .IPMI_INTF_USB = flag(enabled[pluginIndex("usb")]),
        .ENABLE_INTF_OPEN_DUAL_BRIDGE = flag(false),

        // Misc feature switches. src/ipmitool.c uses HAVE_READLINE to expose
        // "shell" in the command table, including with the Zig line editor.
        .ENABLE_ALL_OPTIONS = flag(all_options),
        .ENABLE_FILE_SECURITY = flag(file_security),
        .HAVE_READLINE = flag(ipmishell),
        // configure.ac's anonymous-bitfield probe never succeeds, so autotools
        // always defines this; keep the same layout decision.
        .HAVE_PRAGMA_PACK = flag(true),

        .IANADIR = iana_dir,
        .IANAUSERDIR = iana_user_dir,
        .PATH_SEPARATOR = if (is_windows) "\\" else "/",
    });

    // -- shared C module -----------------------------------------------------

    var cflags: std.ArrayList([]const u8) = .empty;
    cflags.appendSlice(b.allocator, &base_cflags) catch @panic("OOM");
    if (buildcheck) cflags.appendSlice(b.allocator, &buildcheck_cflags) catch @panic("OOM");
    const flags = cflags.toOwnedSlice(b.allocator) catch @panic("OOM");

    const core_mod = b.createModule(.{
        .root_source_file = emptyCoreRoot(b, zig_selection),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = if (sanitize_c) .full else .off,
    });
    configure(b, core_mod, config_h, default_intf);
    addSources(b, core_mod, lib_sources, flags, zig_selection);
    addSources(b, core_mod, intf_sources, flags, zig_selection);
    for (plugins, 0..) |plugin, i| {
        if (!enabled[i]) continue;
        addSources(b, core_mod, plugin.sources, flags, zig_selection);
    }
    const core = b.addLibrary(.{
        .name = "ipmitool_core",
        .linkage = .static,
        .root_module = core_mod,
    });

    // -- Zig replacement library --------------------------------------------
    //
    // `ipmi_c` is the Zig -> C half of the bridge: `translate-c` output for the
    // headers listed in `src/zig/ipmi_c.h`, built with the same include path,
    // config header and macros a C translation unit sees.  `libipmitool_zig.a`
    // is the C -> Zig half: it carries the `@export`ed replacements for the
    // translation units named in `-Dzig-modules`.

    const bridge = b.addTranslateC(.{
        .root_source_file = b.path(zig_bridge_header),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bridge.addConfigHeader(config_h);
    bridge.addIncludePath(b.path("include"));
    bridge.defineCMacro("HAVE_CONFIG_H", "1");
    bridge.defineCMacro("DEFAULT_INTF", b.fmt("\"{s}\"", .{default_intf}));
    if (replacedByZig("src/plugins/usb/usb.c", zig_selection)) {
        bridge.defineCMacro("IPMITOOL_ZIG_USB", "1");
    }
    const bridge_mod = bridge.createModule();

    const zig_options = b.addOptions();
    zig_options.addOption([]const []const u8, "zig_modules", selectedZigModules(b, zig_selection));
    zig_options.addOption(bool, "have_crypto_sha256", openssl);

    const zig_lib: ?*std.Build.Step.Compile = if (anySelected(zig_selection)) blk: {
        const mod = b.createModule(.{
            .root_source_file = b.path(zig_root ++ "/exports.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = if (sanitize_c) .full else .off,
        });
        mod.addImport("ipmi_c", bridge_mod);
        mod.addImport("build_options", zig_options.createModule());
        addZigCShims(b, mod, config_h, default_intf, flags, zig_selection);
        break :blk b.addLibrary(.{
            .name = "ipmitool_zig",
            .linkage = .static,
            .root_module = mod,
        });
    } else null;

    // System libraries are attached to the executables rather than to the
    // static archive: a `.a` cannot usefully carry shared objects.
    var system_libs: std.ArrayList([]const u8) = .empty;
    var swapped_system_libs: std.ArrayList([]const u8) = .empty;
    // lib/Makefile.am: libipmitool_la_LIBADD = -lm
    if (!is_windows) {
        system_libs.append(b.allocator, "m") catch @panic("OOM");
        swapped_system_libs.append(b.allocator, "m") catch @panic("OOM");
    }
    if (ipmishell) {
        for (readline_libs) |lib| system_libs.append(b.allocator, lib) catch @panic("OOM");
    }
    for (plugins, 0..) |plugin, i| {
        if (!enabled[i]) continue;
        for (plugin.system_libs) |lib| {
            if (std.mem.eql(u8, lib, "crypto")) continue;
            system_libs.append(b.allocator, lib) catch @panic("OOM");
            swapped_system_libs.append(b.allocator, lib) catch @panic("OOM");
        }
    }
    const base_libs = system_libs.toOwnedSlice(b.allocator) catch @panic("OOM");
    const swapped_base_libs = swapped_system_libs.toOwnedSlice(b.allocator) catch @panic("OOM");

    // `-lcrypto` is added last and only if something still calls into it, so a
    // build with the crypto ports selected links no OpenSSL at all.
    const libs = withLibcrypto(b, base_libs, openssl, internal_md5, zig_selection);
    // The swapped binary the golden suite builds has every module selected.
    const swapped_libs = withLibcrypto(b, swapped_base_libs, openssl, internal_md5, &all_selected);

    // -- executables ---------------------------------------------------------

    const ipmitool = addTool(b, .{
        .name = "ipmitool",
        .sources = ipmitool_sources,
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
        .config_h = config_h,
        .default_intf = default_intf,
        .flags = flags,
        .core = core,
        .bridge_mod = bridge_mod,
        .have_crypto_sha256 = openssl,
        .zig_lib = zig_lib,
        .zig_selection = zig_selection,
        .system_libs = libs,
    });
    const ipmievd = addTool(b, .{
        .name = "ipmievd",
        .sources = ipmievd_sources,
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
        .config_h = config_h,
        .default_intf = default_intf,
        .flags = flags,
        .core = core,
        .bridge_mod = bridge_mod,
        .have_crypto_sha256 = openssl,
        .zig_lib = zig_lib,
        .zig_selection = zig_selection,
        .system_libs = libs,
    });

    // -- install layout ------------------------------------------------------
    //
    // Matches `make install`: bin/ipmitool, sbin/ipmievd, share/man/man{1,8},
    // share/ipmitool (pkgdatadir) and share/doc/ipmitool (docdir).

    b.installArtifact(ipmitool);
    b.getInstallStep().dependOn(&b.addInstallArtifact(ipmievd, .{
        .dest_dir = .{ .override = .{ .custom = "sbin" } },
    }).step);

    const man_subs = [_]Substitution{
        .{ .name = "IANADIR", .value = iana_dir },
        .{ .name = "IANAUSERDIR", .value = iana_user_dir },
    };
    const man_pages = b.addWriteFiles();
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        substitute(b, man_pages, "doc/ipmitool.1.in", "ipmitool.1", &man_subs),
        .prefix,
        "share/man/man1/ipmitool.1",
    ).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        substitute(b, man_pages, "doc/ipmievd.8.in", "ipmievd.8", &man_subs),
        .prefix,
        "share/man/man8/ipmievd.8",
    ).step);

    for (contrib_data) |name| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path(b.fmt("contrib/{s}", .{name})),
            .prefix,
            b.fmt("share/ipmitool/{s}", .{name}),
        ).step);
    }
    for (contrib_scripts) |name| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path(b.fmt("contrib/{s}", .{name})),
            .prefix,
            b.fmt("share/ipmitool/contrib/{s}", .{name}),
        ).step);
    }
    for (doc_files) |name| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path(name),
            .prefix,
            b.fmt("share/doc/ipmitool/{s}", .{name}),
        ).step);
    }

    if (registry_download) {
        const fetch = b.addSystemCommand(&.{
            "curl",   "--location", "--silent", "--show-error",
            "--fail", "--output",
        });
        const registry = fetch.addOutputFileArg("enterprise-numbers");
        fetch.addArg(iana_pen_url);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            registry,
            .prefix,
            "share/misc/enterprise-numbers",
        ).step);
    }

    // -- `zig build run` -----------------------------------------------------

    const run_cmd = b.addRunArtifact(ipmitool);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run ipmitool with the given arguments").dependOn(&run_cmd.step);

    const run_evd = b.addRunArtifact(ipmievd);
    run_evd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_evd.addArgs(args);
    b.step("run-ipmievd", "Run ipmievd with the given arguments").dependOn(&run_evd.step);

    // -- `zig build gen-crypto-vectors` --------------------------------------
    //
    // Re-derives `tests/crypto/vectors/` from the OpenSSL-backed C crypto
    // sources (issue #9).  It is the only thing left in the tree that needs
    // libcrypto once the ports below are selected, it writes into the source
    // tree, and it is therefore deliberately outside `zig build` and
    // `zig build test`.  See doc/zig-migration/crypto.md.

    addCryptoVectorGenerator(b, .{
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
        .config_h = config_h,
        .default_intf = default_intf,
        .flags = flags,
    });

    // -- `zig build test` ----------------------------------------------------
    //
    // Smoke tests, the Zig/C ABI parity assertions, and the golden CLI suite.

    const test_step = b.step("test", "Run the build smoke tests");

    if (allSelected(zig_selection) and is_linux) {
        const no_varargs_step = b.step("test-no-log-varargs", "Check the all-selected archives have no project C objects or C variadic logger");
        const check = b.addSystemCommand(&.{ "python3", "-B", "tests/logging_no_varargs.py" });
        check.addArtifactArg(zig_lib.?);
        check.addArtifactArg(core);
        no_varargs_step.dependOn(&check.step);
        test_step.dependOn(no_varargs_step);
    }

    const evd_test_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/front/ipmievd.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    evd_test_mod.addImport("ipmi_c", bridge_mod);
    addEvdImports(b, evd_test_mod, bridge_mod, target, optimize, zig_selection, openssl);
    evd_test_mod.linkLibrary(core);
    if (zig_lib) |lib| evd_test_mod.linkLibrary(lib);
    for (libs) |lib| evd_test_mod.linkSystemLibrary(lib, .{});
    const evd_tests = b.addRunArtifact(b.addTest(.{ .root_module = evd_test_mod }));
    b.step("test-event-daemon", "Run hardware-independent ipmievd tests")
        .dependOn(&evd_tests.step);
    test_step.dependOn(&evd_tests.step);
    if (replacedByZig("src/ipmievd.c", zig_selection) and
        target.result.os.tag == .linux and
        b.graph.host.result.os.tag == .linux and
        target.result.cpu.arch == b.graph.host.result.cpu.arch)
    {
        const alive_test = b.addSystemCommand(&.{ "python3", "-B" });
        alive_test.addFileArg(b.path("tests/event_daemon_alive.py"));
        const process_test = b.addSystemCommand(&.{ "python3", "-B" });
        process_test.addFileArg(b.path("tests/event_daemon/process.py"));
        process_test.addFileArg(ipmievd.getEmittedBin());
        process_test.step.dependOn(&alive_test.step);
        b.step("test-event-daemon-process", "Exercise signals and daemon PID lifecycle")
            .dependOn(&process_test.step);
        test_step.dependOn(&process_test.step);
    }

    // Compiling `src/zig/root.zig` runs every `comptime` layout assertion in
    // the header ports, so this fails the build when a C header and its Zig
    // mirror drift apart. Nothing here is exported; the fd_set C oracle
    // below is linked into tests only, never into production binaries.
    const abi_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_mod.addImport("ipmi_c", bridge_mod);
    // This standalone unit root has no selected archive to own logger state.
    const abi_options = b.addOptions();
    abi_options.addOption([]const []const u8, "zig_modules", &.{});
    abi_options.addOption(bool, "have_crypto_sha256", openssl);
    abi_mod.addImport("build_options", abi_options.createModule());
    abi_mod.addCSourceFile(.{ .file = b.path("tests/fd_set_oracle.c"), .flags = &.{"-std=c11"} });
    abi_mod.addCSourceFile(.{ .file = b.path("tests/session_info_mac_oracle.c"), .flags = &.{"-std=c11"} });
    configure(b, abi_mod, config_h, default_intf);
    abi_mod.addCSourceFiles(.{
        .files = &.{ "tests/mc_guid_stdout_deps.c", "lib/ipmi_time.c" },
        .flags = &base_cflags,
    });
    addCryptoVectors(b, abi_mod);
    const abi_tests = b.addTest(.{ .root_module = abi_mod });
    const unit_tests = b.addRunArtifact(abi_tests);
    const unit_step = b.step("test-unit", "Run Zig in-module unit and ABI tests");
    unit_step.dependOn(&unit_tests.step);

    const password_file_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cli.main.test.password file line"},
    });
    const password_file_step = b.step("test-cli-password-file", "Compare CLI password file line framing and trimming with libc");
    password_file_step.dependOn(&b.addRunArtifact(password_file_unit).step);
    test_step.dependOn(password_file_step);

    const dummy_posix_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"intf.dummy.test."},
    });
    const dummy_posix_step = b.step("test-dummy-posix", "Run dummy AF_UNIX syscall, framing, retry and path parity tests");
    dummy_posix_step.dependOn(&b.addRunArtifact(dummy_posix_unit).step);
    test_step.dependOn(dummy_posix_step);

    const stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"util.stdout.test."},
    });
    b.step("test-stdout-unit", "Run Zig stdout formatting and write-failure tests")
        .dependOn(&b.addRunArtifact(stdout_unit).step);

    const raw_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.raw.test.raw stdout"},
    });
    const raw_stdout_step = b.step("test-raw-output", "Compare C/Zig raw response bytes and test writer failures");
    raw_stdout_step.dependOn(&b.addRunArtifact(raw_stdout_unit).step);

    const raw_c_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    configure(b, raw_c_mod, config_h, default_intf);
    raw_c_mod.addCSourceFiles(.{
        .files = &.{ "tests/raw_response_stdout.c", "lib/ipmi_raw.c" },
        .flags = &base_cflags,
    });
    const raw_c = b.addExecutable(.{ .name = "raw-response-c", .root_module = raw_c_mod });

    const raw_options = b.addOptions();
    raw_options.addOption([]const []const u8, "zig_modules", &.{"raw"});
    raw_options.addOption(bool, "have_crypto_sha256", openssl);
    const raw_lib_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/exports.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    raw_lib_mod.addImport("ipmi_c", bridge_mod);
    raw_lib_mod.addImport("build_options", raw_options.createModule());
    const raw_lib = b.addLibrary(.{
        .name = "raw_response_zig",
        .linkage = .static,
        .root_module = raw_lib_mod,
    });
    const raw_zig_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    configure(b, raw_zig_mod, config_h, default_intf);
    raw_zig_mod.addCSourceFile(.{ .file = b.path("tests/raw_response_stdout.c"), .flags = &base_cflags });
    raw_zig_mod.linkLibrary(raw_lib);
    const raw_zig = b.addExecutable(.{ .name = "raw-response-zig", .root_module = raw_zig_mod });

    const raw_compare = b.addSystemCommand(&.{ "python3", "-B", "tests/raw_response_stdout.py" });
    raw_compare.addFileArg(raw_c.getEmittedBin());
    raw_compare.addFileArg(raw_zig.getEmittedBin());
    raw_stdout_step.dependOn(&raw_compare.step);
    test_step.dependOn(raw_stdout_step);

    const raw_i2c_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.raw.test.raw i2c stdout"},
    });
    const raw_i2c_stdout_step = b.step("test-raw-i2c-stdout", "Compare I2C response C bytes, output ordering, and I/O failures");
    raw_i2c_stdout_step.dependOn(&b.addRunArtifact(raw_i2c_stdout_unit).step);
    test_step.dependOn(raw_i2c_stdout_step);

    const gendev_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.gendev.test.gendev stdout"},
    });
    const gendev_stdout_step = b.step("test-gendev-stdout", "Compare gendev progress C bytes, ordering, and I/O failures");
    gendev_stdout_step.dependOn(&b.addRunArtifact(gendev_stdout_unit).step);
    test_step.dependOn(gendev_stdout_step);

    const isol_info_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.isol.test.info stdout"},
    });
    const isol_info_step = b.step("test-isol-info-stdout", "Check ISOL info C bytes, output ordering, and I/O failures");
    isol_info_step.dependOn(&b.addRunArtifact(isol_info_unit).step);
    test_step.dependOn(isol_info_step);

    const sol_payload_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.sol.test.payload status stdout"},
    });
    const sol_payload_step = b.step("test-sol-payload-stdout", "Compare SOL payload status C bytes and test writer failures");
    sol_payload_step.dependOn(&b.addRunArtifact(sol_payload_unit).step);
    test_step.dependOn(sol_payload_step);

    const sol_info_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.sol.test.sol info stdout"},
    });
    const sol_info_stdout_step = b.step("test-sol-info-stdout", "Compare SOL info C bytes, output ordering, and I/O failures");
    sol_info_stdout_step.dependOn(&b.addRunArtifact(sol_info_stdout_unit).step);
    test_step.dependOn(sol_info_stdout_step);

    const sol_interactive_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.sol.test.sol interactive stdout"},
    });
    const sol_interactive_stdout_step = b.step("test-sol-interactive-stdout", "Compare interactive SOL C bytes, terminal statuses, output order and failures");
    sol_interactive_stdout_step.dependOn(&b.addRunArtifact(sol_interactive_stdout_unit).step);
    test_step.dependOn(sol_interactive_stdout_step);

    const user_summary_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.user.test.summary stdout"},
    });
    const user_summary_step = b.step("test-user-summary-stdout", "Compare user summary C bytes and test writer failures");
    user_summary_step.dependOn(&b.addRunArtifact(user_summary_unit).step);
    test_step.dependOn(user_summary_step);

    const user_list_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.user.test.list stdout"},
    });
    const user_list_step = b.step("test-user-list-stdout", "Compare user list C bytes, header lifetime, output order and I/O failures");
    user_list_step.dependOn(&b.addRunArtifact(user_list_unit).step);
    test_step.dependOn(user_list_step);

    const picmg_properties_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.picmg.test.properties stdout"},
    });
    const picmg_properties_step = b.step("test-picmg-properties-stdout", "Compare PICMG properties C bytes, request statuses, output order and I/O failures");
    picmg_properties_step.dependOn(&b.addRunArtifact(picmg_properties_unit).step);
    test_step.dependOn(picmg_properties_step);

    const mc_selftest_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.selftest stdout"},
    });
    const mc_selftest_step = b.step("test-mc-selftest-stdout", "Compare MC selftest C bytes and test writer failures");
    mc_selftest_step.dependOn(&b.addRunArtifact(mc_selftest_unit).step);
    test_step.dependOn(mc_selftest_step);

    const chassis_selftest_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.chassis.test.chassis selftest"},
    });
    const chassis_selftest_stdout_step = b.step("test-chassis-selftest-stdout", "Compare chassis selftest C bytes, statuses, output order and failures");
    chassis_selftest_stdout_step.dependOn(&b.addRunArtifact(chassis_selftest_stdout_unit).step);
    test_step.dependOn(chassis_selftest_stdout_step);

    const chassis_identify_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.chassis.test.chassis identify"},
    });
    const chassis_identify_stdout_step = b.step("test-chassis-identify-stdout", "Compare chassis identify C bytes, requests, output order and I/O failures");
    chassis_identify_stdout_step.dependOn(&b.addRunArtifact(chassis_identify_stdout_unit).step);
    test_step.dependOn(chassis_identify_stdout_step);
    const chassis_status_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.chassis.test.chassis status stdout"},
    });
    const chassis_status_stdout_step = b.step("test-chassis-status-stdout", "Compare chassis status C bytes, optional fields, output order and I/O failures");
    chassis_status_stdout_step.dependOn(&b.addRunArtifact(chassis_status_stdout_unit).step);
    test_step.dependOn(chassis_status_stdout_step);

    const chassis_power_status_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.chassis.test.chassis power status"},
    });
    const chassis_power_status_stdout_step = b.step("test-chassis-power-status-stdout", "Compare chassis power status C bytes, requests, output order and I/O failures");
    chassis_power_status_stdout_step.dependOn(&b.addRunArtifact(chassis_power_status_stdout_unit).step);
    test_step.dependOn(chassis_power_status_stdout_step);

    const chassis_poh_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.chassis.test.chassis poh stdout"},
    });
    const chassis_poh_stdout_step = b.step("test-chassis-poh-stdout", "Compare chassis power-on-hours C bytes, requests, output order and I/O failures");
    chassis_poh_stdout_step.dependOn(&b.addRunArtifact(chassis_poh_stdout_unit).step);
    test_step.dependOn(chassis_poh_stdout_step);

    const chassis_restart_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.chassis.test.chassis restart cause stdout"},
    });
    const chassis_restart_stdout_step = b.step("test-chassis-restart-stdout", "Compare chassis restart cause C bytes, output order and I/O failures");
    chassis_restart_stdout_step.dependOn(&b.addRunArtifact(chassis_restart_stdout_unit).step);
    test_step.dependOn(chassis_restart_stdout_step);

    const chassis_bootparam_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{ "cmd.chassis.test.chassis bootparam stdout", "cmd.chassis.test.chassis bootdev stdout" },
    });
    const chassis_bootparam_stdout_step = b.step("test-chassis-bootparam-stdout", "Compare boot-option reads and bootdev acknowledgments, statuses, output order and I/O failures");
    chassis_bootparam_stdout_step.dependOn(&b.addRunArtifact(chassis_bootparam_stdout_unit).step);
    test_step.dependOn(chassis_bootparam_stdout_step);

    const chassis_comma_tokens_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.chassis.test.chassis comma tokens"},
    });
    const chassis_comma_tokens_step = b.step("test-chassis-comma-tokens", "Compare boot option tokenization and mutated arguments with libc");
    chassis_comma_tokens_step.dependOn(&b.addRunArtifact(chassis_comma_tokens_unit).step);
    test_step.dependOn(chassis_comma_tokens_step);

    const chassis_cstrings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.chassis.test.chassis cstrings"},
    });
    const chassis_cstrings_step = b.step("test-chassis-cstrings", "Compare chassis command strings, prefixes and lengths with libc");
    chassis_cstrings_step.dependOn(&b.addRunArtifact(chassis_cstrings_unit).step);
    test_step.dependOn(chassis_cstrings_step);

    const chassis_mailbox_requests_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.chassis.test.chassis mailbox request"},
    });
    const chassis_mailbox_requests_step = b.step("test-chassis-mailbox-requests", "Check bounded mailbox request strings, truncation, and block order against C");
    chassis_mailbox_requests_step.dependOn(&b.addRunArtifact(chassis_mailbox_requests_unit).step);
    test_step.dependOn(chassis_mailbox_requests_step);

    const chassis_log_hex_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/chassis_log_hex_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    chassis_log_hex_mod.addImport("ipmi_c", bridge_mod);
    chassis_log_hex_mod.addImport("build_options", abi_options.createModule());
    configure(b, chassis_log_hex_mod, config_h, default_intf);
    const chassis_log_hex_unit = b.addTest(.{
        .root_module = chassis_log_hex_mod,
        .filters = &.{"cmd.chassis.test.chassis bootparam log hex"},
    });
    const chassis_log_hex_step = b.step("test-chassis-log-hex", "Compare chassis boot-parameter log hex bytes, truncation and lifetimes with libc");
    chassis_log_hex_step.dependOn(&b.addRunArtifact(chassis_log_hex_unit).step);
    test_step.dependOn(chassis_log_hex_step);

    const chassis_control_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.chassis.test.chassis control stdout"},
    });
    const chassis_control_stdout_step = b.step("test-chassis-control-stdout", "Compare chassis power-control C bytes, request statuses, output order and I/O failures");
    chassis_control_stdout_step.dependOn(&b.addRunArtifact(chassis_control_stdout_unit).step);
    test_step.dependOn(chassis_control_stdout_step);

    const chassis_policy_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.chassis.test.chassis policy stdout"},
    });
    const chassis_policy_stdout_step = b.step("test-chassis-policy-stdout", "Compare chassis restore-policy C bytes, request statuses, output order and I/O failures");
    chassis_policy_stdout_step.dependOn(&b.addRunArtifact(chassis_policy_stdout_unit).step);
    test_step.dependOn(chassis_policy_stdout_step);

    const mc_reset_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.reset stdout"},
    });
    const mc_reset_step = b.step("test-mc-reset-stdout", "Compare MC reset C bytes and test writer failures");
    mc_reset_step.dependOn(&b.addRunArtifact(mc_reset_unit).step);
    test_step.dependOn(mc_reset_step);

    const mc_completion_names_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.mc non-watchdog completion"},
    });
    const mc_completion_names_step = b.step("test-mc-completion-names", "Compare MC completion-name NUL and unknown formatting with libc");
    mc_completion_names_step.dependOn(&b.addRunArtifact(mc_completion_names_unit).step);
    test_step.dependOn(mc_completion_names_step);

    const mc_enables_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.global enables stdout"},
    });
    const mc_enables_step = b.step("test-mc-enables-stdout", "Compare MC Global Enables C bytes, statuses and output failures");
    mc_enables_step.dependOn(&b.addRunArtifact(mc_enables_unit).step);
    test_step.dependOn(mc_enables_step);

    const mc_watchdog_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.watchdog ack stdout"},
    });
    const mc_watchdog_step = b.step("test-mc-watchdog-stdout", "Compare MC watchdog acknowledgements with C and test writer failures");
    mc_watchdog_step.dependOn(&b.addRunArtifact(mc_watchdog_unit).step);
    test_step.dependOn(mc_watchdog_step);

    const mc_watchdog_get_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.watchdog get stdout"},
    });
    const mc_watchdog_get_step = b.step("test-mc-watchdog-get-stdout", "Compare MC watchdog get C bytes, statuses, output order and I/O failures");
    mc_watchdog_get_step.dependOn(&b.addRunArtifact(mc_watchdog_get_unit).step);
    test_step.dependOn(mc_watchdog_get_step);

    const mc_watchdog_numeric_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.watchdog numeric"},
    });
    const mc_watchdog_numeric_step = b.step("test-mc-watchdog-numeric", "Compare MC watchdog SET decimal parsing, request bytes and statuses with libc");
    mc_watchdog_numeric_step.dependOn(&b.addRunArtifact(mc_watchdog_numeric_unit).step);
    test_step.dependOn(mc_watchdog_numeric_step);

    const mc_watchdog_equals_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.watchdog equals"},
    });
    const mc_watchdog_equals_step = b.step("test-mc-watchdog-equals", "Compare watchdog option value pointers and requests with libc");
    mc_watchdog_equals_step.dependOn(&b.addRunArtifact(mc_watchdog_equals_unit).step);
    test_step.dependOn(mc_watchdog_equals_step);

    const mc_info_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.mc info stdout"},
    });
    const mc_info_step = b.step("test-mc-info-stdout", "Compare MC info C bytes, output ordering, and I/O failures");
    mc_info_step.dependOn(&b.addRunArtifact(mc_info_unit).step);
    test_step.dependOn(mc_info_step);

    const mc_info_names_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.mc info"},
    });
    const mc_info_names_step = b.step("test-mc-info-names", "Compare MC manufacturer and product lookup bytes and fallback formatting with C");
    mc_info_names_step.dependOn(&b.addRunArtifact(mc_info_names_unit).step);
    test_step.dependOn(mc_info_names_step);

    const mc_guid_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.mc guid stdout"},
    });
    const mc_guid_step = b.step("test-mc-guid-stdout", "Compare MC GUID C bytes, statuses, output ordering, and I/O failures");
    mc_guid_step.dependOn(&b.addRunArtifact(mc_guid_unit).step);
    test_step.dependOn(mc_guid_step);

    const mc_sysinfo_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.mc sysinfo stdout"},
    });
    const mc_sysinfo_step = b.step("test-mc-sysinfo-stdout", "Compare MC sysinfo C bytes, request statuses, output order and failures");
    mc_sysinfo_step.dependOn(&b.addRunArtifact(mc_sysinfo_unit).step);
    test_step.dependOn(mc_sysinfo_step);

    const mc_sysinfo_set_copy_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.mc sysinfo SET copy"},
    });
    const mc_sysinfo_set_copy_step = b.step("test-mc-sysinfo-set-copy", "Compare MC sysinfo SET blocks with libc and verify request failures");
    mc_sysinfo_set_copy_step.dependOn(&b.addRunArtifact(mc_sysinfo_set_copy_unit).step);
    test_step.dependOn(mc_sysinfo_set_copy_step);

    const mc_strcmp_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.mc.test.mc strcmp"},
    });
    const mc_strcmp_step = b.step("test-mc-strcmp", "Compare MC C-string equality, selectors, dispatch and request statuses with libc");
    mc_strcmp_step.dependOn(&b.addRunArtifact(mc_strcmp_unit).step);
    test_step.dependOn(mc_strcmp_step);

    const channel_strings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.channel.test.channel strings"},
    });
    const channel_strings_step = b.step("test-channel-strings", "Compare channel IANA formatting and payload matching with libc");
    channel_strings_step.dependOn(&b.addRunArtifact(channel_strings_unit).step);
    test_step.dependOn(channel_strings_step);

    const dcmi_strings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.dcmi.test.DCMI strings"},
    });
    const dcmi_strings_step = b.step("test-dcmi-strings", "Compare DCMI unknown labels and command equality with libc");
    dcmi_strings_step.dependOn(&b.addRunArtifact(dcmi_strings_unit).step);
    test_step.dependOn(dcmi_strings_step);

    const dcmi_asset_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.dcmi.test.DCMI asset stdout"},
    });
    const dcmi_asset_step = b.step("test-dcmi-asset-stdout", "Compare DCMI asset and MC ID raw C bytes, requests, partial output, ordering and failures");
    dcmi_asset_step.dependOn(&b.addRunArtifact(dcmi_asset_unit).step);
    test_step.dependOn(dcmi_asset_step);

    const firewall_matrix_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.firewall.test.firewall command matrix"},
    });
    const firewall_matrix_step = b.step("test-firewall-list-stdout", "Compare firewall command-mask C bytes, output order, and I/O failures");
    firewall_matrix_step.dependOn(&b.addRunArtifact(firewall_matrix_unit).step);
    test_step.dependOn(firewall_matrix_step);

    const quanta_desc_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.quantaoem.test.Quanta memory event description"},
    });
    const quanta_desc_step = b.step("test-quanta-desc", "Compare all Quanta memory descriptions with libc");
    quanta_desc_step.dependOn(&b.addRunArtifact(quanta_desc_unit).step);
    test_step.dependOn(quanta_desc_step);

    const nm_strings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.nm.test.nm strings"},
    });
    const nm_strings_step = b.step("test-nm-strings", "Compare Node Manager unknown labels and help with libc");
    nm_strings_step.dependOn(&b.addRunArtifact(nm_strings_unit).step);
    test_step.dependOn(nm_strings_step);

    const sel_time_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.sel.test.sel time stdout"},
    });
    const sel_time_stdout_step = b.step("test-sel-time-stdout", "Compare SEL time C bytes, request statuses, buffered output order, and I/O failures");
    sel_time_stdout_step.dependOn(&b.addRunArtifact(sel_time_stdout_unit).step);
    test_step.dependOn(sel_time_stdout_step);

    const sel_info_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.sel.test.sel info stdout"},
    });
    const sel_info_stdout_step = b.step("test-sel-info-stdout", "Compare SEL info C bytes, request statuses, output order and I/O failures");
    sel_info_stdout_step.dependOn(&b.addRunArtifact(sel_info_stdout_unit).step);
    test_step.dependOn(sel_info_stdout_step);

    const sel_cstrings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.sel.test.sel cstrings"},
    });
    const sel_cstrings_step = b.step("test-sel-cstrings", "Compare SEL tokens, PPS line lengths and Dell DIMM digits with libc");
    sel_cstrings_step.dependOn(&b.addRunArtifact(sel_cstrings_unit).step);
    test_step.dependOn(sel_cstrings_step);

    const sel_add_strings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.sel.test.sel add strings"},
    });
    const sel_add_strings_step = b.step("test-sel-add-strings", "Compare SEL add clipping, whitespace, diagnostics and token bytes with libc");
    sel_add_strings_step.dependOn(&b.addRunArtifact(sel_add_strings_unit).step);
    test_step.dependOn(sel_add_strings_step);

    const sdr_unit_strings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.sdr.test.sdr unit strings"},
    });
    const sdr_unit_strings_step = b.step("test-sdr-unit-strings", "Compare SDR unit labels and truncation with libc");
    sdr_unit_strings_step.dependOn(&b.addRunArtifact(sdr_unit_strings_unit).step);
    test_step.dependOn(sdr_unit_strings_step);

    const fru_strings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.fru.test.fru string lengths"},
    });
    const fru_strings_step = b.step("test-fru-strings", "Compare FRU string lengths, file statuses and multirecord labels with libc");
    fru_strings_step.dependOn(&b.addRunArtifact(fru_strings_unit).step);
    test_step.dependOn(fru_strings_step);

    const kontron_strings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.kontronoem.test.Kontron decoded FRU serial lengths"},
    });
    const kontron_strings_step = b.step("test-kontron-strings", "Compare Kontron decoded FRU serial lengths with libc");
    kontron_strings_step.dependOn(&b.addRunArtifact(kontron_strings_unit).step);
    test_step.dependOn(kontron_strings_step);

    const session_info_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.session.test.session info stdout"},
    });
    const session_info_step = b.step("test-session-info-stdout", "Compare C/Zig session info CLI output and test writer failures");
    session_info_step.dependOn(&b.addRunArtifact(session_info_unit).step);
    test_step.dependOn(session_info_step);

    const session_strings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.session.test.session command and interface names"},
    });
    const session_strings_step = b.step("test-session-strings", "Compare session command and bounded interface names with libc");
    session_strings_step.dependOn(&b.addRunArtifact(session_strings_unit).step);
    test_step.dependOn(session_strings_step);

    const password_test_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.user.test.password test stdout"},
    });
    const password_test_step = b.step("test-user-password-test-stdout", "Compare user password test C output and test writer failures");
    password_test_step.dependOn(&b.addRunArtifact(password_test_unit).step);
    test_step.dependOn(password_test_step);

    const password_prompt_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.user.test.user password prompt"},
    });
    const password_prompt_step = b.step("test-user-password-prompt", "Compare all user password prompts and static buffer contents with libc");
    password_prompt_step.dependOn(&b.addRunArtifact(password_prompt_unit).step);
    test_step.dependOn(password_prompt_step);

    const user_write_ack_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.user.test.user write acknowledgement stdout"},
    });
    const user_write_ack_step = b.step("test-user-write-ack-stdout", "Compare user privilege/password C bytes, output order and I/O failures");
    user_write_ack_step.dependOn(&b.addRunArtifact(user_write_ack_unit).step);
    test_step.dependOn(user_write_ack_step);

    const lan_activate_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"intf.lan.test.activate session stderr"},
    });
    b.step("test-lan-activate-stderr", "Check LAN activation stderr bytes, C logging order, and write failures")
        .dependOn(&b.addRunArtifact(lan_activate_unit).step);

    const event_sample_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.event.test.sample event stdout"},
    });
    const event_sample_step = b.step("test-event-sample-stdout", "Compare sample event C bytes and test writer failures");
    event_sample_step.dependOn(&b.addRunArtifact(event_sample_unit).step);
    test_step.dependOn(event_sample_step);

    const event_sensor_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.event.test.sensor lookup stdout"},
    });
    const event_sensor_stdout_step = b.step("test-event-sensor-stdout", "Compare sensor lookup C bytes and test output failures");
    event_sensor_stdout_step.dependOn(&b.addRunArtifact(event_sensor_stdout_unit).step);
    test_step.dependOn(event_sensor_stdout_step);

    const event_cstrings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.event.test.event cstrings"},
    });
    const event_cstrings_step = b.step("test-event-cstrings", "Compare event strings, comment offsets and lengths with libc");
    event_cstrings_step.dependOn(&b.addRunArtifact(event_cstrings_unit).step);
    test_step.dependOn(event_cstrings_step);

    const event_space_tokens_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.event.test.event space tokens"},
    });
    const event_space_tokens_step = b.step("test-event-space-tokens", "Compare bounded event-file space tokens with libc");
    event_space_tokens_step.dependOn(&b.addRunArtifact(event_space_tokens_unit).step);
    test_step.dependOn(event_space_tokens_step);

    const event_file_line_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.event.test.event file line"},
    });
    const event_file_line_step = b.step("test-event-file-line", "Compare bounded event-file line framing and read errors with libc");
    event_file_line_step.dependOn(&b.addRunArtifact(event_file_line_unit).step);
    test_step.dependOn(event_file_line_step);

    const pong_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"intf.lanplus.test.pong stdout"},
    });
    b.step("test-lanplus-pong-stdout", "Check RMCP pong stdout formatting and write failures")
        .dependOn(&b.addRunArtifact(pong_stdout_unit).step);

    const lanplus_data_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"intf.lanplus.test.ipmi payload stderr"},
    });
    b.step("test-lanplus-data-stderr", "Compare LAN+ verbose data hex with C and reject write failures")
        .dependOn(&b.addRunArtifact(lanplus_data_unit).step);

    const lanplus_lengths_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"intf.lanplus.test.lanplus lengths"},
    });
    const lanplus_lengths_step = b.step("test-lanplus-lengths", "Compare bounded LAN+ username and hostname lengths with libc");
    lanplus_lengths_step.dependOn(&b.addRunArtifact(lanplus_lengths_unit).step);
    test_step.dependOn(lanplus_lengths_step);

    const dump_stdout_step = b.step("test-lanplus-dump-stdout", "Compare C/Zig LAN+ dump bytes and test writer failures");
    const dump_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"intf.lanplus_dump.test.dump stdout"},
    });
    dump_stdout_step.dependOn(&b.addRunArtifact(dump_stdout_unit).step);
    if (enabled[pluginIndex("lanplus")]) {
        inline for (.{ false, true }) |sha256| {
            const feature = if (sha256) "1" else "0";
            const suffix = if (sha256) "sha256" else "no-sha256";
            const dump_bridge = b.addTranslateC(.{
                .root_source_file = b.path("tests/lanplus_dump_bridge.h"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            dump_bridge.addConfigHeader(config_h);
            dump_bridge.addIncludePath(b.path("include"));
            dump_bridge.defineCMacro("HAVE_CONFIG_H", "1");
            dump_bridge.defineCMacro("DEFAULT_INTF", b.fmt("\"{s}\"", .{default_intf}));
            dump_bridge.defineCMacro("LANPLUS_DUMP_TEST_SHA256", feature);

            const c_dump_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
            configure(b, c_dump_mod, config_h, default_intf);
            c_dump_mod.addCMacro("LANPLUS_DUMP_TEST_SHA256", feature);
            c_dump_mod.addCSourceFiles(.{
                .files = &.{ "tests/lanplus_dump_stdout.c", "tests/lanplus_dump_oracle.c" },
                .flags = &base_cflags,
            });
            const c_dump = b.addExecutable(.{ .name = "lanplus-dump-c-" ++ suffix, .root_module = c_dump_mod });

            const dump_options = b.addOptions();
            dump_options.addOption([]const []const u8, "zig_modules", &.{"lanplus-dump"});
            dump_options.addOption(bool, "have_crypto_sha256", sha256);
            const zig_dump_lib_mod = b.createModule(.{
                .root_source_file = b.path(zig_root ++ "/exports.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            zig_dump_lib_mod.addImport("ipmi_c", dump_bridge.createModule());
            zig_dump_lib_mod.addImport("build_options", dump_options.createModule());
            const zig_dump_lib = b.addLibrary(.{
                .name = "lanplus-dump-zig-" ++ suffix,
                .linkage = .static,
                .root_module = zig_dump_lib_mod,
            });
            const zig_dump_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
            configure(b, zig_dump_mod, config_h, default_intf);
            zig_dump_mod.addCSourceFile(.{ .file = b.path("tests/lanplus_dump_stdout.c"), .flags = &base_cflags });
            zig_dump_mod.linkLibrary(zig_dump_lib);
            const zig_dump = b.addExecutable(.{ .name = "lanplus-dump-zig-" ++ suffix, .root_module = zig_dump_mod });

            const compare = b.addSystemCommand(&.{ "python3", "tests/lanplus_dump_stdout.py", suffix });
            compare.addFileArg(c_dump.getEmittedBin());
            compare.addFileArg(zig_dump.getEmittedBin());
            dump_stdout_step.dependOn(&compare.step);
        }
    }
    test_step.dependOn(dump_stdout_step);

    const helper_valstr_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"util.helper.test.valstr stdout"},
    });
    b.step("test-helper-valstr-unit", "Check value-table stdout formatting against libc")
        .dependOn(&b.addRunArtifact(helper_valstr_unit).step);

    const helper_integer_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"util.helper.test.integer base-zero"},
    });
    const helper_integer_step = b.step("test-helper-integers", "Compare Zig base-zero integer conversions, values and errno with libc");
    helper_integer_step.dependOn(&b.addRunArtifact(helper_integer_unit).step);
    test_step.dependOn(helper_integer_step);

    const valstr_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configure(b, valstr_c_mod, config_h, default_intf);
    valstr_c_mod.addCSourceFiles(.{
        .files = &.{ "tests/helper_valstr_stdout.c", "lib/helper.c", "lib/log.c" },
        .flags = &base_cflags,
    });
    const valstr_c = b.addExecutable(.{ .name = "helper-valstr-c", .root_module = valstr_c_mod });

    const valstr_options = b.addOptions();
    valstr_options.addOption([]const []const u8, "zig_modules", &.{"helper"});
    valstr_options.addOption(bool, "have_crypto_sha256", openssl);
    const valstr_lib_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/exports.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    valstr_lib_mod.addImport("ipmi_c", bridge_mod);
    valstr_lib_mod.addImport("build_options", valstr_options.createModule());
    const valstr_lib = b.addLibrary(.{
        .name = "helper_valstr_zig",
        .linkage = .static,
        .root_module = valstr_lib_mod,
    });
    const valstr_zig_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configure(b, valstr_zig_mod, config_h, default_intf);
    valstr_zig_mod.addCSourceFiles(.{
        .files = &.{ "tests/helper_valstr_stdout.c", "lib/log.c" },
        .flags = &base_cflags,
    });
    valstr_zig_mod.linkLibrary(valstr_lib);
    const valstr_zig = b.addExecutable(.{ .name = "helper-valstr-zig", .root_module = valstr_zig_mod });
    const valstr_golden =
        "C before one\nCodes:\n\n" ++
        "  VALUE\tHEX\tSTRING\n==============================================\n" ++
        "  255\t0xff\tA\n  256\t0x0100\tB\n  -1\t0xffffffff\tC\n\n" ++
        "C after one\n" ++
        "C before two\nCodes:\n\n" ++
        "   255  A" ++ (" " ** 31) ++ "     256  B" ++ (" " ** 31) ++ "\n" ++
        "    -1  C" ++ (" " ** 31) ++ "\n\n" ++
        "C after two\n";
    const valstr_step = b.step("test-helper-valstr-golden", "Compare both stdout printers and mixed C/Zig output order");
    inline for (.{ valstr_c, valstr_zig }) |fixture| {
        const run = b.addRunArtifact(fixture);
        run.setEnvironmentVariable("LC_ALL", "C");
        run.expectStdOutEqual(valstr_golden);
        run.expectStdErrEqual("");
        valstr_step.dependOn(&run.step);
    }
    test_step.dependOn(valstr_step);

    const strings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"util.strings.test."},
    });
    b.step("test-strings-unit", "Run lookup table unit and C header assertions")
        .dependOn(&b.addRunArtifact(strings_unit).step);
    b.step("test-strings-compile", "Cross-compile lookup table C header assertions")
        .dependOn(&strings_unit.step);

    const strings_tables_step = b.step("test-strings-tables", "Test pure-Zig tables with and without SHA256");
    inline for (.{ false, true }) |sha256| {
        const feature_options = b.addOptions();
        feature_options.addOption(bool, "have_crypto_sha256", sha256);
        const table_mod = b.createModule(.{
            .root_source_file = b.path("src/zig/util/strings_tables_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        table_mod.addImport("build_options", feature_options.createModule());
        strings_tables_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = table_mod })).step);
    }
    test_step.dependOn(strings_tables_step);

    const strings_lookup_step = b.step("test-strings-lookup-data", "Test C-free lookup rules with and without SHA256");
    inline for (.{ false, true }) |sha256| {
        const feature_options = b.addOptions();
        feature_options.addOption(bool, "have_crypto_sha256", sha256);
        const lookup_mod = b.createModule(.{
            .root_source_file = b.path("src/zig/util/strings.zig"),
            .target = target,
            .optimize = optimize,
        });
        lookup_mod.addImport("build_options", feature_options.createModule());
        strings_lookup_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lookup_mod })).step);
    }
    test_step.dependOn(strings_lookup_step);

    const registry_parse_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/util/registry_parse.zig"),
        .target = target,
        .optimize = optimize,
    });
    const registry_parse_step = b.step("test-registry-parse", "Test header-free IANA registry parsing");
    registry_parse_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = registry_parse_mod })).step);
    test_step.dependOn(registry_parse_step);

    const assert_text_step = b.step("test-assert-text-data", "Test C-free assertion text with and without SHA256");
    inline for (.{ false, true }) |sha256| {
        const feature_options = b.addOptions();
        feature_options.addOption(bool, "have_crypto_sha256", sha256);
        const text_mod = b.createModule(.{
            .root_source_file = b.path("src/zig/crypto/assert_text_data_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        text_mod.addImport("build_options", feature_options.createModule());
        assert_text_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = text_mod })).step);
    }
    test_step.dependOn(assert_text_step);

    const fd_set_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{ "fd_set matches libc macros", "intf.open.test." },
    });
    b.step("test-fdset", "Run fd_set boundary and OpenIPMI model tests")
        .dependOn(&b.addRunArtifact(fd_set_unit).step);
    b.step("test-fdset-compile", "Cross-compile fd_set ABI parity tests")
        .dependOn(&fd_set_unit.step);

    const open_path_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"intf.open.test.open device paths"},
    });
    b.step("test-open-device-path", "Compare bounded OpenIPMI device paths with libc and reject overflow")
        .dependOn(&b.addRunArtifact(open_path_unit).step);

    const open_verbose_step = b.step("test-open-verbose-stderr", "Compare original and Zig OpenIPMI stderr bytes and mixed C output order");
    var open_c_exe: *std.Build.Step.Compile = undefined;
    var open_zig_exe: *std.Build.Step.Compile = undefined;
    inline for (.{ false, true }) |selected| {
        const fixture_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        configure(b, fixture_mod, config_h, default_intf);
        fixture_mod.addCSourceFiles(.{
            .files = if (selected)
                &.{"tests/open_verbose_stderr.c"}
            else
                &.{ "tests/open_verbose_stderr.c", "src/plugins/open/open.c" },
            .flags = &base_cflags,
        });
        if (selected) {
            const options = b.addOptions();
            options.addOption([]const []const u8, "zig_modules", &.{"open"});
            options.addOption(bool, "have_crypto_sha256", openssl);
            const exports_mod = b.createModule(.{
                .root_source_file = b.path(zig_root ++ "/exports.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            exports_mod.addImport("ipmi_c", bridge_mod);
            exports_mod.addImport("build_options", options.createModule());
            fixture_mod.linkLibrary(b.addLibrary(.{
                .name = "open-verbose-exports",
                .linkage = .static,
                .root_module = exports_mod,
            }));
        }
        const exe = b.addExecutable(.{
            .name = if (selected) "open-verbose-zig" else "open-verbose-c",
            .root_module = fixture_mod,
        });
        if (selected) {
            open_zig_exe = exe;
        } else {
            open_c_exe = exe;
        }
    }
    const open_verbose_compare = b.addSystemCommand(&.{ "python3", "-B", "tests/open_verbose_stderr.py" });
    open_verbose_compare.addArtifactArg(open_c_exe);
    open_verbose_compare.addArtifactArg(open_zig_exe);
    open_verbose_step.dependOn(&open_verbose_compare.step);
    test_step.dependOn(open_verbose_step);

    const time_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{ "the unspecified timestamp ignores the format", "Unknown timestamp matches snprintf" },
    });
    b.step("test-time-unit", "Run timestamp Unknown-format parity tests")
        .dependOn(&b.addRunArtifact(time_unit).step);

    const shell_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"quoted shell words"},
    });
    b.step("test-shell-unit", "Run shared shell and script word parser tests")
        .dependOn(&b.addRunArtifact(shell_unit).step);

    const shell_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"frontend.shell_commands.test.shell stdout"},
    });
    b.step("test-shell-stdout-unit", "Compare shell stdout formats with libc and reject writer failures")
        .dependOn(&b.addRunArtifact(shell_stdout_unit).step);

    const exec_line_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"frontend.shell_commands.test.exec line scanner"},
    });
    b.step("test-exec-line-input", "Compare bounded Zig exec lines with the fgets/fgetc/strlen oracle")
        .dependOn(&b.addRunArtifact(exec_line_unit).step);

    const fwum_test_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/fwum_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fwum_test_mod.addImport("ipmi_c", bridge_mod);
    fwum_test_mod.addIncludePath(b.path("include"));
    fwum_test_mod.addCSourceFile(.{ .file = b.path("lib/log.c"), .flags = &.{} });
    fwum_test_mod.addCSourceFile(.{ .file = b.path("tests/fwum_progress_oracle.c"), .flags = &.{"-std=c11"} });
    const fwum_tests = b.addTest(.{ .root_module = fwum_test_mod });
    const fwum_test_run = b.addRunArtifact(fwum_tests);
    unit_step.dependOn(&fwum_test_run.step);
    b.step("test-fwum-unit", "Run bounded FWUM retries and firmware metadata tests")
        .dependOn(&fwum_test_run.step);
    const fwum_oracle = b.addTest(.{
        .root_module = fwum_test_mod,
        .filters = &.{"cmd.fwum.test.fwum C progress oracle"},
    });
    b.step("test-fwum-progress-oracle", "Characterize the original C FWUM progress bytes")
        .dependOn(&b.addRunArtifact(fwum_oracle).step);
    const fwum_stdout = b.addTest(.{
        .root_module = fwum_test_mod,
        .filters = &.{"cmd.fwum.test.fwum progress stdout"},
    });
    const fwum_stdout_step = b.step("test-fwum-progress-output", "Compare FWUM progress to libc and check stdout order and I/O failures");
    fwum_stdout_step.dependOn(&b.addRunArtifact(fwum_stdout).step);
    fwum_stdout_step.dependOn(&b.addRunArtifact(fwum_oracle).step);
    const fwum_cli_c_mod = b.createModule(.{ .target = b.graph.host, .optimize = .Debug, .link_libc = true });
    fwum_cli_c_mod.addCSourceFiles(.{
        .files = &.{ "tests/fwum_progress_cli.c", "tests/fwum_progress_oracle.c" },
        .flags = &.{"-std=c11"},
    });
    const fwum_cli_c = b.addExecutable(.{ .name = "fwum-progress-c", .root_module = fwum_cli_c_mod });
    const fwum_cli_zig_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/fwum_progress_cli.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    fwum_cli_zig_mod.addImport("ipmi_c", bridge_mod);
    const fwum_cli_zig = b.addExecutable(.{ .name = "fwum-progress-zig", .root_module = fwum_cli_zig_mod });
    const fwum_cli_compare = b.addSystemCommand(&.{ "python3", "-B", "tests/fwum_progress_cli.py" });
    fwum_cli_compare.addFileArg(fwum_cli_c.getEmittedBin());
    fwum_cli_compare.addFileArg(fwum_cli_zig.getEmittedBin());
    fwum_cli_compare.addFileArg(b.path("tests/fwum/snapshots/progress_output_cli.snap"));
    fwum_stdout_step.dependOn(&fwum_cli_compare.step);
    test_step.dependOn(fwum_stdout_step);

    test_step.dependOn(unit_step);

    const log_step = b.step("test-log", "Check native Zig logging against the C oracle and C ABI");
    const log_compile_step = b.step("test-log-compile", "Compile both logging ABI fixtures without executing them");
    const frontend_log_step = b.step("test-log-frontends", "Check the frontend logging ABI with C and Zig logger state");
    const log_prefix =
        "lazy 3\n" ++
        "7: 0x002a left      +3 %\n";
    const log_tail =
        "ABI 11\n" ++
        "errno native: No such file or directory\n" ++
        "ABI errno 5: Permission denied\n" ++
        ": Invalid or incomplete multibyte or wide character\n" ++
        ("x" ** 1023) ++ "\n" ++
        "openlog:parity-daemon\n" ++
        "syslog:6:daemon yes  -2\n" ++
        "syslog:5:ABI daemon 12\n" ++
        "syslog:3:daemon error: No such file or directory\n" ++
        "closelog\n" ++
        "reset\n";
    const log_expected = log_prefix ++
        "  Allocating     42 entries\n" ++
        "  [    42]       -3 | Acme\n" ++
        "  42\t0x2a\tAcme\n" ++ log_tail;
    const frontend_log_expected = log_prefix ++ log_tail;
    inline for (.{ false, true }) |zig_log| {
        const log_options = b.addOptions();
        log_options.addOption([]const []const u8, "zig_modules", if (zig_log) &.{"log"} else &.{});
        log_options.addOption(bool, "have_crypto_sha256", openssl);
        const log_options_mod = log_options.createModule();
        const log_mod = b.createModule(.{
            .root_source_file = b.path("tests/logging.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        log_mod.addImport("ipmi_c", bridge_mod);
        log_mod.addImport("build_options", log_options_mod);
        const log_headers = b.createModule(.{
            .root_source_file = b.path("src/zig/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        log_headers.addImport("ipmi_c", bridge_mod);
        log_headers.addImport("build_options", log_options_mod);
        log_mod.addImport("ipmi_zig", log_headers);
        configure(b, log_mod, config_h, default_intf);
        log_mod.addCSourceFiles(.{
            .root = b.path("."),
            .files = if (zig_log)
                &.{ "src/zig/util/log_varargs.c", "tests/logging_syslog.c" }
            else
                &.{ "lib/log.c", "tests/logging_syslog.c" },
            .flags = flags,
        });
        const log_exe = b.addExecutable(.{
            .name = if (zig_log) "logging-zig" else "logging-c",
            .root_module = log_mod,
        });
        log_compile_step.dependOn(&log_exe.step);
        const log_run = b.addRunArtifact(log_exe);
        log_run.setEnvironmentVariable("LC_ALL", "C");
        log_run.expectStdOutEqual("");
        log_run.expectStdErrEqual(log_expected);
        log_step.dependOn(&log_run.step);

        const frontend_mod = b.createModule(.{
            .root_source_file = b.path("tests/frontend_logging.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        frontend_mod.addImport("ipmi_c", bridge_mod);
        frontend_mod.addImport("build_options", log_options_mod);
        const frontend_logger_mod = b.createModule(.{
            .root_source_file = b.path("src/zig/frontend/logging.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        frontend_logger_mod.addImport("ipmi_c", bridge_mod);
        frontend_logger_mod.addImport("build_options", log_options_mod);
        frontend_mod.addImport("frontend_log", frontend_logger_mod);
        configure(b, frontend_mod, config_h, default_intf);
        frontend_mod.addCSourceFiles(.{
            .root = b.path("."),
            .files = if (zig_log)
                &.{ "src/zig/util/log_varargs.c", "tests/logging_syslog.c" }
            else
                &.{ "lib/log.c", "tests/logging_syslog.c" },
            .flags = flags,
        });
        if (zig_log) {
            const exports_mod = b.createModule(.{
                .root_source_file = b.path(zig_root ++ "/exports.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            exports_mod.addImport("ipmi_c", bridge_mod);
            exports_mod.addImport("build_options", log_options_mod);
            const exports_lib = b.addLibrary(.{
                .name = "frontend_log_exports",
                .linkage = .static,
                .root_module = exports_mod,
            });
            frontend_mod.linkLibrary(exports_lib);
        }
        const frontend_exe = b.addExecutable(.{
            .name = if (zig_log) "frontend-logging-zig" else "frontend-logging-c",
            .root_module = frontend_mod,
        });
        log_compile_step.dependOn(&frontend_exe.step);
        const frontend_run = b.addRunArtifact(frontend_exe);
        frontend_run.setEnvironmentVariable("LC_ALL", "C");
        frontend_run.expectStdOutEqual("");
        frontend_run.expectStdErrEqual(frontend_log_expected);
        frontend_log_step.dependOn(&frontend_run.step);
    }
    test_step.dependOn(log_step);
    test_step.dependOn(frontend_log_step);

    if (is_linux) {
        const evd_only: [zig_modules.len]bool = blk: {
            var selected: [zig_modules.len]bool = @splat(false);
            selected[moduleIndex("evd")] = true;
            break :blk selected;
        };
        const evd_and_log: [zig_modules.len]bool = blk: {
            var selected = evd_only;
            selected[moduleIndex("log")] = true;
            break :blk selected;
        };
        const daemon_options = SwappedOptions{
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .config_h = config_h,
            .default_intf = default_intf,
            .flags = flags,
            .plugins_enabled = &enabled,
            .bridge_mod = bridge_mod,
            .have_crypto_sha256 = openssl,
            .system_libs = withLibcrypto(b, base_libs, openssl, internal_md5, &evd_only),
        };
        const daemon_c = addSelectedTool(b, daemon_options, &evd_only, "ipmievd-log-c");
        const daemon_zig = addSelectedTool(b, daemon_options, &evd_and_log, "ipmievd-log-zig");
        inline for (.{ daemon_c, daemon_zig }) |daemon| {
            daemon.root_module.addCSourceFile(.{
                .file = b.path("tests/event_daemon/syslog_sink.c"),
                .flags = &base_cflags,
            });
        }
        const daemon_log_step = b.step("test-event-daemon-log", "Compare Zig daemon with C and Zig logger selections");
        daemon_log_step.dependOn(frontend_log_step);
        test_step.dependOn(daemon_log_step);
        const parity = b.addSystemCommand(&.{ "python3", "-B" });
        parity.addFileArg(b.path("tests/event_daemon/logging.py"));
        parity.addFileArg(daemon_c.getEmittedBin());
        parity.addFileArg(daemon_zig.getEmittedBin());
        parity.addDirectoryArg(b.tmpPath());
        daemon_log_step.dependOn(&parity.step);
        inline for (.{ daemon_c, daemon_zig }) |daemon| {
            const process = b.addSystemCommand(&.{ "python3", "-B" });
            process.addFileArg(b.path("tests/event_daemon/process.py"));
            process.addFileArg(daemon.getEmittedBin());
            daemon_log_step.dependOn(&process.step);
        }
    }

    const spd_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{ "SPD decoder", "JEDEC table" },
    });
    b.step("test-dimm-spd-unit", "Run Zig DIMM SPD decoder and table unit tests")
        .dependOn(&b.addRunArtifact(spd_unit).step);
    const spd_tables_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/spd_tables_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spd_tables_run = b.addRunArtifact(b.addTest(.{ .root_module = spd_tables_mod }));
    b.step("test-dimm-spd-tables", "Test generated SPD tables without the translated C bridge")
        .dependOn(&spd_tables_run.step);
    test_step.dependOn(&spd_tables_run.step);
    const serial_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"serial "},
    });
    b.step("test-serial-unit", "Run Zig serial framing and ABI unit tests")
        .dependOn(&b.addRunArtifact(serial_unit).step);

    // Link the same fixture against the original registry and its Zig
    // replacement. It supplies only vtable instances and compares listing,
    // selection, session parameters, payload sizes and UDP routing.
    const registry_unit_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/registry_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    registry_unit_mod.addImport("ipmi_c", bridge_mod);
    const registry_unit = b.addRunArtifact(b.addTest(.{ .root_module = registry_unit_mod }));

    const registry_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configure(b, registry_c_mod, config_h, default_intf);
    registry_c_mod.addCSourceFiles(.{
        .files = &.{ "tests/intf_registry_contract.c", "src/plugins/ipmi_intf.c" },
        .flags = &base_cflags,
    });
    const registry_c = b.addExecutable(.{ .name = "intf-registry-c", .root_module = registry_c_mod });

    const registry_options = b.addOptions();
    registry_options.addOption([]const []const u8, "zig_modules", &.{"intf"});
    registry_options.addOption(bool, "have_crypto_sha256", openssl);
    const registry_lib_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/exports.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    registry_lib_mod.addImport("ipmi_c", bridge_mod);
    registry_lib_mod.addImport("build_options", registry_options.createModule());
    const registry_lib = b.addLibrary(.{
        .name = "intf_registry_fixture",
        .linkage = .static,
        .root_module = registry_lib_mod,
    });
    const registry_zig_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configure(b, registry_zig_mod, config_h, default_intf);
    registry_zig_mod.addCSourceFile(.{
        .file = b.path("tests/intf_registry_contract.c"),
        .flags = &base_cflags,
    });
    registry_zig_mod.linkLibrary(registry_lib);
    const registry_zig = b.addExecutable(.{ .name = "intf-registry-zig", .root_module = registry_zig_mod });
    const registry_run = b.addSystemCommand(&.{ "python3", "tests/intf_registry_contract.py" });
    registry_run.addArtifactArg(registry_c);
    registry_run.addArtifactArg(registry_zig);
    const registry_step = b.step("test-intf-registry", "Compare C and Zig registry ABI and behavior");
    registry_step.dependOn(&registry_run.step);
    registry_step.dependOn(&registry_unit.step);
    test_step.dependOn(registry_step);

    const lanp6_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"LAN6 "},
    });
    b.step("test-lanp6-unit", "Run IPv6 LAN configuration parser and reply tests")
        .dependOn(&b.addRunArtifact(lanp6_unit).step);
    const pef_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"PEF "},
    });
    b.step("test-pef-unit", "Run Zig PEF validation and formatting unit tests")
        .dependOn(&b.addRunArtifact(pef_unit).step);
    const pef_strings_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{ "cmd.pef.test.PEF strings match libc", "cmd.pef.test.PEF trigger labels and prefixes match libc", "cmd.pef.test.PEF trigger suffixes match bounded libc", "cmd.pef.test.PEF LAN IPv4 bytes match libc" },
    });
    b.step("test-pef-strings", "Compare PEF command, trigger and IPv4 bytes with libc")
        .dependOn(&b.addRunArtifact(pef_strings_unit).step);
    const pef_status_stdout_unit = b.addTest(.{
        .root_module = abi_mod,
        .filters = &.{"cmd.pef.test.PEF enable status stdout"},
    });
    b.step("test-pef-status-stdout", "Compare PEF enable announcements with libc and check stdout failures")
        .dependOn(&b.addRunArtifact(pef_status_stdout_unit).step);

    const lanp_test_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/lanp_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lanp_test_mod.addImport("ipmi_c", bridge_mod);
    const lanp_unit = b.addTest(.{ .root_module = lanp_test_mod });
    const lanp_step = b.step("test-lanp", "Run LAN parameter encoding and reply validation tests");
    lanp_step.dependOn(&b.addRunArtifact(lanp_unit).step);
    test_step.dependOn(lanp_step);

    // The golden harness cannot supply getpass()'s static buffer or a NULL
    // prompt result. Exercise the actual C and Zig user modules with the same
    // scripted prompt and sendrecv stubs.
    const user_step = b.step("test-user", "Test C and Zig user password commands");
    const c_user_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configure(b, c_user_mod, config_h, default_intf);
    c_user_mod.addCSourceFiles(.{
        .files = &.{ "tests/user_password.c", "lib/ipmi_user.c" },
        .flags = flags,
        .language = .c,
    });
    const c_user_test = b.addExecutable(.{ .name = "user-password-c", .root_module = c_user_mod });
    user_step.dependOn(&b.addRunArtifact(c_user_test).step);

    const user_only = parseZigModules(b, "user");
    const user_options = b.addOptions();
    user_options.addOption([]const []const u8, "zig_modules", selectedZigModules(b, user_only));
    user_options.addOption(bool, "have_crypto_sha256", openssl);
    const zig_user_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/exports.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zig_user_mod.addImport("ipmi_c", bridge_mod);
    zig_user_mod.addImport("build_options", user_options.createModule());
    const zig_user_lib = b.addLibrary(.{ .name = "user-password-zig-lib", .linkage = .static, .root_module = zig_user_mod });

    const zig_user_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configure(b, zig_user_test_mod, config_h, default_intf);
    zig_user_test_mod.addCSourceFiles(.{
        .files = &.{"tests/user_password.c"},
        .flags = flags,
        .language = .c,
    });
    zig_user_test_mod.linkLibrary(zig_user_lib);
    const zig_user_test = b.addExecutable(.{ .name = "user-password-zig", .root_module = zig_user_test_mod });
    user_step.dependOn(&b.addRunArtifact(zig_user_test).step);
    test_step.dependOn(user_step);

    const usb_test_step = b.step("test-usb", "Run the model SCSI generic USB transport tests");
    if (!is_linux) {
        usb_test_step.dependOn(&b.addFail("test-usb needs Linux SG_IO").step);
    } else if (!enabled[pluginIndex("usb")] and
        !replacedByZig("src/plugins/usb/usb.c", zig_selection))
    {
        usb_test_step.dependOn(&b.addFail("test-usb needs -Dintf-usb=true or -Dzig-modules=usb").step);
    } else {
        const usb_unit_tests = b.addTest(.{
            .root_module = abi_mod,
            .filters = &.{"intf.usb.test."},
        });
        usb_test_step.dependOn(&b.addRunArtifact(usb_unit_tests).step);
    }

    // Compile the same C ABI contract against the original objects and the
    // three Zig replacements. The harness supplies a scripted sendrecv,
    // logging and parameter callbacks; neither binary needs a real BMC.
    const support_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configure(b, support_c_mod, config_h, default_intf);
    support_c_mod.addCSourceFiles(.{
        .files = &.{
            "tests/command_support.c",
            "lib/ipmi_cfgp.c",
            "lib/ipmi_session.c",
            "lib/hpm2.c",
        },
        // The unchanged C oracle has warnings under -Dbuildcheck's -Werror.
        .flags = &base_cflags,
    });
    const support_c = b.addExecutable(.{ .name = "command-support-c", .root_module = support_c_mod });

    const support_zig_options = b.addOptions();
    support_zig_options.addOption(
        []const []const u8,
        "zig_modules",
        &.{ "cfgp", "session", "hpm2" },
    );
    support_zig_options.addOption(bool, "have_crypto_sha256", openssl);
    const support_lib_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/exports.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    support_lib_mod.addImport("ipmi_c", bridge_mod);
    support_lib_mod.addImport("build_options", support_zig_options.createModule());
    const support_lib = b.addLibrary(.{
        .name = "command_support_zig",
        .linkage = .static,
        .root_module = support_lib_mod,
    });
    const support_zig_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configure(b, support_zig_mod, config_h, default_intf);
    support_zig_mod.addCSourceFile(.{ .file = b.path("tests/command_support.c"), .flags = &base_cflags });
    support_zig_mod.linkLibrary(support_lib);
    const support_zig = b.addExecutable(.{ .name = "command-support-zig", .root_module = support_zig_mod });
    const support_step = b.step("test-command-support", "Run C/Zig cfgp, session and HPM.2 ABI contracts");
    support_step.dependOn(&b.addRunArtifact(support_c).step);
    support_step.dependOn(&b.addRunArtifact(support_zig).step);
    test_step.dependOn(support_step);

    const lanplus_strings_step = b.step("test-lanplus-strings", "Check C and Zig LAN+ lookup tables and their ABI");
    const lanplus_data_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/lanplus_strings_data_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    lanplus_strings_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lanplus_data_mod })).step);
    const c_strings_mod = b.createModule(.{
        .root_source_file = b.path("tests/lanplus_strings.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_strings_mod.addImport("ipmi_c", bridge_mod);
    addEvdImports(b, c_strings_mod, bridge_mod, target, optimize, null, openssl);
    configure(b, c_strings_mod, config_h, default_intf);
    c_strings_mod.addCSourceFile(.{
        .file = b.path("src/plugins/lanplus/lanplus_strings.c"),
        .flags = &base_cflags,
    });
    lanplus_strings_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = c_strings_mod })).step);

    const zig_strings_options = b.addOptions();
    zig_strings_options.addOption([]const []const u8, "zig_modules", &.{"lanplus-strings"});
    zig_strings_options.addOption(bool, "have_crypto_sha256", openssl);
    const zig_strings_exports = b.createModule(.{
        .root_source_file = b.path("src/zig/exports.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zig_strings_exports.addImport("ipmi_c", bridge_mod);
    zig_strings_exports.addImport("build_options", zig_strings_options.createModule());
    const zig_strings_lib = b.addLibrary(.{
        .name = "lanplus-strings-zig",
        .linkage = .static,
        .root_module = zig_strings_exports,
    });
    const zig_strings_mod = b.createModule(.{
        .root_source_file = b.path("tests/lanplus_strings.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zig_strings_mod.addImport("ipmi_c", bridge_mod);
    addEvdImports(b, zig_strings_mod, bridge_mod, target, optimize, null, openssl);
    zig_strings_mod.linkLibrary(zig_strings_lib);
    lanplus_strings_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = zig_strings_mod })).step);
    test_step.dependOn(lanplus_strings_step);

    const ime_test_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/ime_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ime_test_mod.addImport("ipmi_c", bridge_mod);
    const ime_tests = b.addTest(.{ .root_module = ime_test_mod });
    b.step("test-ime", "Run isolated Intel ME firmware update unit tests")
        .dependOn(&b.addRunArtifact(ime_tests).step);

    const ekanalyzer_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/ekanalyzer_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ekanalyzer_mod.addImport("ipmi_c", bridge_mod);
    const ekanalyzer_tests = b.addRunArtifact(b.addTest(.{ .root_module = ekanalyzer_mod }));
    const ekanalyzer_step = b.step("test-ekanalyzer", "Run offline FRU/PICMG bounds tests");
    ekanalyzer_step.dependOn(&ekanalyzer_tests.step);
    test_step.dependOn(ekanalyzer_step);
    const ekanalyzer_header_unit = b.addTest(.{
        .root_module = ekanalyzer_mod,
        .filters = &.{"cmd.ekanalyzer.test.header stdout"},
    });
    const ekanalyzer_header_step = b.step("test-ekanalyzer-header-stdout", "Compare EKey FRU header C bytes, output order and I/O failures");
    ekanalyzer_header_step.dependOn(&b.addRunArtifact(ekanalyzer_header_unit).step);
    test_step.dependOn(ekanalyzer_header_step);

    if (replacedByZig("src/ipmishell.c", zig_selection)) {
        const shell_pty = b.addSystemCommand(&.{
            "python3",
            b.pathFromRoot("tests/shell/pty.py"),
        });
        shell_pty.setEnvironmentVariable("IPMITOOL_TEST_ZIG_MC_RESET", if (replacedByZig("lib/ipmi_mc.c", zig_selection)) "1" else "0");
        shell_pty.setEnvironmentVariable("IPMITOOL_TEST_C_BUFFERED_POH", if (replacedByZig("lib/ipmi_chassis.c", zig_selection)) "0" else "1");
        shell_pty.addArtifactArg(ipmitool);
        const shell_test = b.step("test-shell", "Run native shell PTY and CLI tests");
        shell_test.dependOn(&shell_pty.step);
        test_step.dependOn(&shell_pty.step);

        if (replacedByZig("lib/ipmi_chassis.c", zig_selection)) {
            const hybrid_selection = b.allocator.dupe(bool, zig_selection) catch @panic("OOM");
            hybrid_selection[moduleIndex("chassis")] = false;
            const hybrid = addSelectedTool(b, .{
                .target = target,
                .optimize = optimize,
                .sanitize_c = sanitize_c,
                .config_h = config_h,
                .default_intf = default_intf,
                .flags = flags,
                .plugins_enabled = &enabled,
                .bridge_mod = bridge_mod,
                .have_crypto_sha256 = openssl,
                .system_libs = withLibcrypto(b, base_libs, openssl, internal_md5, hybrid_selection),
            }, hybrid_selection, "ipmitool-shell-c-chassis");
            const hybrid_pty = b.addSystemCommand(&.{
                "python3",
                b.pathFromRoot("tests/shell/pty.py"),
            });
            hybrid_pty.setEnvironmentVariable("IPMITOOL_TEST_ZIG_MC_RESET", if (replacedByZig("lib/ipmi_mc.c", hybrid_selection)) "1" else "0");
            hybrid_pty.setEnvironmentVariable("IPMITOOL_TEST_C_BUFFERED_POH", "1");
            hybrid_pty.addArtifactArg(hybrid);
            shell_test.dependOn(&hybrid_pty.step);
            test_step.dependOn(&hybrid_pty.step);
        }
    }

    const dell_test_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/delloem_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dell_test_mod.addImport("ipmi_c", bridge_mod);
    const dell_tests = b.addTest(.{ .root_module = dell_test_mod });
    const dell_step = b.step("test-delloem", "Run Dell OEM Zig parser and wire-layout tests");
    dell_step.dependOn(&b.addRunArtifact(dell_tests).step);
    test_step.dependOn(dell_step);

    const sunoem_test_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/sunoem_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sunoem_test_mod.addImport("ipmi_c", bridge_mod);
    const sunoem_tests = b.addRunArtifact(b.addTest(.{ .root_module = sunoem_test_mod }));
    b.step("test-sunoem", "Run focused Sun OEM parser and ABI tests").dependOn(&sunoem_tests.step);

    // Every registered Zig module has to keep compiling even when it is not
    // selected, otherwise a port only breaks for whoever passes the flag.
    if (zig_lib) |lib| test_step.dependOn(&lib.step);

    const version_check = b.addRunArtifact(ipmitool);
    version_check.addArg("-V");
    version_check.expectStdOutEqual(b.fmt("ipmitool version {s}\n", .{version}));
    test_step.dependOn(&version_check.step);

    const evd_version_check = b.addRunArtifact(ipmievd);
    evd_version_check.addArg("-V");
    evd_version_check.expectStdOutEqual(b.fmt("ipmievd version {s}\n", .{version}));
    test_step.dependOn(&evd_version_check.step);

    // `-h` writes the usage, including the interface list, to stderr.
    const usage = b.addRunArtifact(ipmitool);
    usage.addArg("-h");
    usage.expectExitCode(0);
    const usage_text = usage.captureStdErr(.{});
    var expected: std.ArrayList([]const u8) = .empty;
    expected.append(b.allocator, "Interfaces:") catch @panic("OOM");
    for (plugins, 0..) |plugin, i| {
        if (!enabled[i]) continue;
        // The serial plugin registers under two different interface names.
        if (std.mem.eql(u8, plugin.name, "serial")) {
            expected.append(b.allocator, "serial-terminal") catch @panic("OOM");
            expected.append(b.allocator, "serial-basic") catch @panic("OOM");
            continue;
        }
        expected.append(b.allocator, plugin.name) catch @panic("OOM");
    }
    const usage_check = b.addCheckFile(usage_text, .{
        .expected_matches = expected.toOwnedSlice(b.allocator) catch @panic("OOM"),
    });
    test_step.dependOn(&usage_check.step);

    const evd_usage = b.addRunArtifact(ipmievd);
    evd_usage.addArg("-h");
    evd_usage.expectExitCode(0);
    _ = evd_usage.captureStdErr(.{});
    test_step.dependOn(&evd_usage.step);

    // -- `zig build test-golden` ---------------------------------------------
    //
    // The golden CLI suite (issue #4).  It drives the `dummy` interface over a
    // Unix socket and compares the exit status, stdout, stderr *and the IPMI
    // request bytes* of every case against committed snapshots, so a Zig port
    // has to be observably identical to the C it replaces -- including on the
    // wire.  See doc/zig-migration/golden-harness.md.
    //
    // `-o list` used to be asserted here as an interim stand-in while this
    // suite lived outside the build; the `global_oem_list` case now covers it
    // (byte-identical stderr, plus the exit status and the absence of IPMI
    // traffic), so there is one obvious place for CLI expectations.

    const golden_exe = b.addExecutable(.{
        .name = "golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/golden/main.zig"),
            // The harness drives the binary under test as a subprocess, so it
            // always builds for the host rather than for `target`.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    if (enabled[pluginIndex("dummy")] and target.result.os.tag == b.graph.host.result.os.tag and
        target.result.cpu.arch == b.graph.host.result.cpu.arch)
    {
        const dummy_c = b.allocator.dupe(bool, zig_selection) catch @panic("OOM");
        const dummy_zig = b.allocator.dupe(bool, zig_selection) catch @panic("OOM");
        dummy_c[moduleIndex("dummy")] = false;
        dummy_zig[moduleIndex("dummy")] = true;
        var dummy_options: SwappedOptions = .{
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .config_h = config_h,
            .default_intf = default_intf,
            .flags = flags,
            .plugins_enabled = &enabled,
            .bridge_mod = bridge_mod,
            .have_crypto_sha256 = openssl,
            .system_libs = undefined,
        };
        const dummy_oracle = if (!zig_selection[moduleIndex("dummy")]) ipmitool else blk: {
            dummy_options.system_libs = withLibcrypto(b, base_libs, openssl, internal_md5, dummy_c);
            break :blk addSelectedTool(b, dummy_options, dummy_c, "ipmitool-dummy-c");
        };
        const dummy_selected = if (zig_selection[moduleIndex("dummy")]) ipmitool else blk: {
            dummy_options.system_libs = withLibcrypto(b, base_libs, openssl, internal_md5, dummy_zig);
            break :blk addSelectedTool(b, dummy_options, dummy_zig, "ipmitool-dummy-zig");
        };
        const dummy_compare = b.addRunArtifact(golden_exe);
        dummy_compare.addArg("--tests-dir");
        dummy_compare.addDirectoryArg(b.path("tests"));
        dummy_compare.addArgs(&.{ "--repo", b.build_root.path orelse ".", "--binary" });
        dummy_compare.addFileArg(dummy_oracle.getEmittedBin());
        dummy_compare.addArg("--candidate");
        dummy_compare.addFileArg(dummy_selected.getEmittedBin());
        dummy_compare.addArgs(&.{ "--allow-uncovered", "--work-dir" });
        dummy_compare.addDirectoryArg(b.tmpPath());
        if (b.args) |args| dummy_compare.addArgs(args);
        b.step("test-dummy-posix-cli", "Compare same-feature C and Zig dummy CLI output, status and wire")
            .dependOn(&dummy_compare.step);

        const session_c = b.allocator.dupe(bool, zig_selection) catch @panic("OOM");
        const session_zig = b.allocator.dupe(bool, zig_selection) catch @panic("OOM");
        session_c[moduleIndex("session")] = false;
        session_zig[moduleIndex("session")] = true;
        var variant_options: SwappedOptions = .{
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .config_h = config_h,
            .default_intf = default_intf,
            .flags = flags,
            .plugins_enabled = &enabled,
            .bridge_mod = bridge_mod,
            .have_crypto_sha256 = openssl,
            .system_libs = undefined,
        };
        const oracle = if (!zig_selection[moduleIndex("session")]) ipmitool else blk: {
            variant_options.system_libs = withLibcrypto(b, base_libs, openssl, internal_md5, session_c);
            break :blk addSelectedTool(b, variant_options, session_c, "ipmitool-session-c");
        };
        const selected = if (zig_selection[moduleIndex("session")]) ipmitool else blk: {
            variant_options.system_libs = withLibcrypto(b, base_libs, openssl, internal_md5, session_zig);
            break :blk addSelectedTool(b, variant_options, session_zig, "ipmitool-session-zig");
        };
        const compare = b.addRunArtifact(golden_exe);
        compare.addArg("--tests-dir");
        compare.addDirectoryArg(b.path("tests"));
        compare.addArgs(&.{ "--repo", b.build_root.path orelse ".", "--binary" });
        compare.addFileArg(oracle.getEmittedBin());
        compare.addArg("--candidate");
        compare.addFileArg(selected.getEmittedBin());
        compare.addArgs(&.{ "--filter", "session_info_", "--allow-uncovered", "--work-dir" });
        compare.addDirectoryArg(b.tmpPath());
        session_info_step.dependOn(&compare.step);
    }

    const golden_step = b.step("test-golden", "Run the golden CLI test suite");
    golden_step.dependOn(&addGolden(
        b,
        golden_exe,
        ipmitool,
        null,
        replacedByZig("lib/ipmi_gendev.c", zig_selection),
        moduleSelected("delloem", zig_selection),
        moduleSelected("ipmishell", zig_selection),
    ).step);
    const fru_oem_step = b.step("test-fru-oem", "Run fixed Zig-only OEM edit cases");
    if (zig_selection[fruIndex()]) {
        fru_oem_step.dependOn(&addFruOemGolden(b, golden_exe, ipmitool).step);
    }

    // The whole point of the suite is to prove that a Zig replacement is
    // observably identical to the C it replaced, so run it a second time
    // against a binary with every registered module swapped to Zig.  This is
    // additive rather than a rebuild: the C objects are shared with the build
    // above through the compilation cache, so only the archive and the two
    // links are redone.  When `-Dzig-modules` already selects everything the
    // second binary is the same as the first and is skipped.
    if (!allSelected(zig_selection)) {
        const swapped = addSwappedTool(b, .{
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .config_h = config_h,
            .default_intf = default_intf,
            .flags = flags,
            .plugins_enabled = &enabled,
            .bridge_mod = bridge_mod,
            .have_crypto_sha256 = openssl,
            .system_libs = swapped_libs,
        });
        golden_step.dependOn(&addGolden(b, golden_exe, swapped, null, true, true, true).step);
        if (!zig_selection[fruIndex()])
            fru_oem_step.dependOn(&addFruOemGolden(b, golden_exe, swapped).step);
    }
    golden_step.dependOn(fru_oem_step);

    test_step.dependOn(golden_step);

    // TSOL requires a LAN interface, a PTY and UDP datagrams. The dummy
    // interface golden harness cannot exercise any of its interactive paths.
    const tsol_step = b.step("test-tsol", "Compare C and Zig TSOL over a PTY and loopback UDP");
    const tsol_oracle_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tsol_oracle_mod.addIncludePath(b.path("include"));
    tsol_oracle_mod.addCSourceFiles(.{
        .root = b.path("."),
        .files = &.{ "tests/tsol/fixture.c", "lib/ipmi_tsol.c" },
        .flags = &.{"-DHAVE_TERMIOS_H"},
    });
    const tsol_oracle = b.addExecutable(.{ .name = "tsol-oracle", .root_module = tsol_oracle_mod });
    const tsol_run = b.addSystemCommand(&.{ "python3", "tests/tsol/run.py", "--oracle" });
    tsol_run.addArtifactArg(tsol_oracle);
    if (replacedByZig("lib/ipmi_tsol.c", zig_selection)) {
        // The fixture stubs TSOL's dependencies, not those of other selected
        // ports such as the CLI. Give it an archive exporting TSOL alone.
        const tsol_only: [zig_modules.len]bool = blk: {
            var selected: [zig_modules.len]bool = @splat(false);
            selected[moduleIndex("tsol")] = true;
            break :blk selected;
        };
        const tsol_options = b.addOptions();
        tsol_options.addOption([]const []const u8, "zig_modules", selectedZigModules(b, &tsol_only));
        tsol_options.addOption(bool, "have_crypto_sha256", openssl);
        const tsol_exports = b.createModule(.{
            .root_source_file = b.path(zig_root ++ "/exports.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        tsol_exports.addImport("ipmi_c", bridge_mod);
        tsol_exports.addImport("build_options", tsol_options.createModule());
        const tsol_lib = b.addLibrary(.{
            .name = "tsol_fixture_zig",
            .linkage = .static,
            .root_module = tsol_exports,
        });
        const tsol_candidate_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        tsol_candidate_mod.addIncludePath(b.path("include"));
        tsol_candidate_mod.addCSourceFiles(.{
            .root = b.path("tests/tsol"),
            .files = &.{"fixture.c"},
            .flags = &.{"-DHAVE_TERMIOS_H"},
        });
        tsol_candidate_mod.linkLibrary(tsol_lib);
        const tsol_candidate = b.addExecutable(.{ .name = "tsol-candidate", .root_module = tsol_candidate_mod });
        tsol_run.addArg("--candidate");
        tsol_run.addArtifactArg(tsol_candidate);
    }
    tsol_step.dependOn(&tsol_run.step);
    test_step.dependOn(tsol_step);

    // Exercise the frontend in isolation: both binaries have identical C
    // backends, with only lib/ipmi_main.c and src/ipmitool.c swapped.  The
    // golden comparison also catches argv permutation and dummy wire traffic;
    // the runtime checks PTY prompts, SIGINT and failed devices/transports.
    if (is_linux) {
        const no_zig: [zig_modules.len]bool = @splat(false);
        const cli_only = blk: {
            var selected = no_zig;
            selected[moduleIndex("cli")] = true;
            break :blk selected;
        };
        const cli_options = SwappedOptions{
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .config_h = config_h,
            .default_intf = default_intf,
            .flags = flags,
            .plugins_enabled = &enabled,
            .bridge_mod = bridge_mod,
            .have_crypto_sha256 = openssl,
            .system_libs = withLibcrypto(b, base_libs, openssl, internal_md5, &no_zig),
        };
        const oracle = addSelectedTool(b, cli_options, &no_zig, "ipmitool-cli-c");
        const candidate = addSelectedTool(b, cli_options, &cli_only, "ipmitool-cli-zig");
        const daemon_oracle = addSelectedTool(b, cli_options, &no_zig, "ipmievd-cli-c");
        const daemon_candidate = addSelectedTool(b, cli_options, &cli_only, "ipmievd-cli-zig");
        const cli_step = b.step("test-cli", "Compare C and Zig CLI, including PTY and SIGINT");
        // Differential cases need /a and /b beneath each case name; a build
        // cache path plus a 36-character case exceeds sockaddr_un.sun_path in
        // longer checkout paths. The harness removes this short scratch root.
        const compare = addGolden(b, golden_exe, oracle, b.pathFromRoot(".cli-golden"), false, false, false);
        compare.addArg("--candidate");
        compare.addFileArg(candidate.getEmittedBin());
        cli_step.dependOn(&compare.step);

        const runtime = b.addSystemCommand(&.{"python3"});
        runtime.addFileArg(b.path("tests/cli/runtime.py"));
        runtime.addArg("--oracle");
        runtime.addFileArg(oracle.getEmittedBin());
        runtime.addArg("--candidate");
        runtime.addFileArg(candidate.getEmittedBin());
        runtime.addArg("--daemon-oracle");
        runtime.addFileArg(daemon_oracle.getEmittedBin());
        runtime.addArg("--daemon-candidate");
        runtime.addFileArg(daemon_candidate.getEmittedBin());
        runtime.addArg("--work-dir");
        runtime.addDirectoryArg(b.tmpPath());
        cli_step.dependOn(&runtime.step);
    }

    if (is_linux and ipmishell) {
        const shell_only: [zig_modules.len]bool = blk: {
            var selected: [zig_modules.len]bool = @splat(false);
            selected[moduleIndex("ipmishell")] = true;
            break :blk selected;
        };
        const cli_and_shell: [zig_modules.len]bool = blk: {
            var selected = shell_only;
            selected[moduleIndex("cli")] = true;
            break :blk selected;
        };
        const cutover_options = SwappedOptions{
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .config_h = config_h,
            .default_intf = default_intf,
            .flags = flags,
            .plugins_enabled = &enabled,
            .bridge_mod = bridge_mod,
            .have_crypto_sha256 = openssl,
            .system_libs = withLibcrypto(b, swapped_base_libs, openssl, internal_md5, &shell_only),
        };
        const oracle = addSelectedTool(b, cutover_options, &shell_only, "ipmitool-cli-cutover-c");
        const candidate = addSelectedTool(b, cutover_options, &cli_and_shell, "ipmitool-cli-cutover-zig");
        const daemon_oracle = addSelectedTool(b, cutover_options, &shell_only, "ipmievd-cli-cutover-c");
        const daemon_candidate = addSelectedTool(b, cutover_options, &cli_and_shell, "ipmievd-cli-cutover-zig");
        const cutover_step = b.step("test-cli-cutover", "Compare C and Zig shared CLI through C daemon and Zig shell callers");
        const compare = addGolden(b, golden_exe, oracle, b.pathFromRoot(".cli-cutover-golden"), false, false, true);
        compare.addArg("--candidate");
        compare.addFileArg(candidate.getEmittedBin());
        cutover_step.dependOn(&compare.step);

        const runtime = b.addSystemCommand(&.{"python3"});
        runtime.addFileArg(b.path("tests/cli/runtime.py"));
        runtime.addArg("--oracle");
        runtime.addFileArg(oracle.getEmittedBin());
        runtime.addArg("--candidate");
        runtime.addFileArg(candidate.getEmittedBin());
        runtime.addArg("--daemon-oracle");
        runtime.addFileArg(daemon_oracle.getEmittedBin());
        runtime.addArg("--daemon-candidate");
        runtime.addFileArg(daemon_candidate.getEmittedBin());
        runtime.addArg("--work-dir");
        runtime.addDirectoryArg(b.tmpPath());
        cutover_step.dependOn(&runtime.step);

        const run = b.addSystemCommand(&.{ "python3", "-B" });
        run.addFileArg(b.path("tests/shell/pty.py"));
        run.addFileArg(candidate.getEmittedBin());
        run.addFileArg(oracle.getEmittedBin());
        run.setEnvironmentVariable("IPMITOOL_TEST_C_BUFFERED_POH", "1");
        cutover_step.dependOn(&run.step);

        const shell_and_log: [zig_modules.len]bool = blk: {
            var selected = shell_only;
            selected[moduleIndex("log")] = true;
            break :blk selected;
        };
        const shell_log_oracle = addSelectedTool(b, cutover_options, &shell_only, "ipmitool-shell-log-c");
        const shell_log_candidate = addSelectedTool(b, cutover_options, &shell_and_log, "ipmitool-shell-log-zig");
        const shell_log_step = b.step("test-shell-log", "Compare C and Zig logger state through the selected shell");
        shell_log_step.dependOn(frontend_log_step);
        const shell_log_compare = addGolden(b, golden_exe, shell_log_oracle, b.pathFromRoot(".shell-log-golden"), false, false, true);
        shell_log_compare.addArg("--candidate");
        shell_log_compare.addFileArg(shell_log_candidate.getEmittedBin());
        shell_log_step.dependOn(&shell_log_compare.step);

        inline for (.{ true, false }) |zig_logger| {
            const shell_run = b.addSystemCommand(&.{ "python3", "-B" });
            shell_run.addFileArg(b.path("tests/shell/pty.py"));
            shell_run.addFileArg(if (zig_logger) shell_log_candidate.getEmittedBin() else shell_log_oracle.getEmittedBin());
            shell_run.addFileArg(if (zig_logger) shell_log_oracle.getEmittedBin() else shell_log_candidate.getEmittedBin());
            shell_log_step.dependOn(&shell_run.step);
        }
    }

    // -- `zig build test-transport` / `gen-transport-fixtures` ---------------
    //
    // The transport fixture harness (issues #10 and #26).  The golden suite
    // above only ever speaks to the `dummy` interface, which has no checksums,
    // no session layer and no packet assembly, so it cannot see any of the
    // code Phase 4 is about.  This harness runs the binary against a model BMC
    // over loopback UDP and byte-compares every datagram.
    // See doc/zig-migration/transport-fixtures.md.

    const transport_exe = b.addExecutable(.{
        .name = "transport-fixtures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/transport/main.zig"),
            // Drives the binary under test as a subprocess, so it is always
            // built for the host.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const transport_step = b.step("test-transport", "Run the transport fixture suite");
    const transport_unit = b.addTest(.{ .root_module = transport_exe.root_module });
    transport_step.dependOn(&b.addRunArtifact(transport_unit).step);

    // The suite needs a binary that actually has the transports compiled in.
    // When they are switched off there is nothing to check, and saying so is
    // better than silently passing.
    if (enabled[pluginIndex("lan")] and enabled[pluginIndex("lanplus")]) {
        transport_step.dependOn(&addTransport(b, transport_exe, ipmitool, false).step);
        if (!allSelected(zig_selection)) {
            const swapped = addSwappedTool(b, .{
                .target = target,
                .optimize = optimize,
                .sanitize_c = sanitize_c,
                .config_h = config_h,
                .default_intf = default_intf,
                .flags = flags,
                .plugins_enabled = &enabled,
                .bridge_mod = bridge_mod,
                .have_crypto_sha256 = openssl,
                .system_libs = swapped_libs,
            });
            transport_step.dependOn(&addTransport(b, transport_exe, swapped, false).step);
        }
        const gen = addTransport(b, transport_exe, ipmitool, true);
        b.step(
            "gen-transport-fixtures",
            "Re-record tests/transport/fixtures from the C transports",
        ).dependOn(&gen.step);
    }

    test_step.dependOn(transport_step);

    // Drive both serial modes through a real PTY and compare the CLI and
    // request bytes to the C implementations, independently of LAN fixtures.
    if (enabled[pluginIndex("serial")] and target.result.os.tag == .linux) {
        const serial_c = b.allocator.dupe(bool, zig_selection) catch @panic("OOM");
        const serial_zig = b.allocator.dupe(bool, zig_selection) catch @panic("OOM");
        inline for ([_][]const u8{ "serial-basic", "serial-terminal" }) |name| {
            serial_c[moduleIndex(name)] = false;
            serial_zig[moduleIndex(name)] = true;
        }
        var variant_options: SwappedOptions = .{
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .config_h = config_h,
            .default_intf = default_intf,
            .flags = flags,
            .plugins_enabled = &enabled,
            .bridge_mod = bridge_mod,
            .have_crypto_sha256 = openssl,
            .system_libs = undefined,
        };
        const oracle = if (!zig_selection[moduleIndex("serial-basic")] and
            !zig_selection[moduleIndex("serial-terminal")]) ipmitool else blk: {
            variant_options.system_libs = withLibcrypto(b, base_libs, openssl, internal_md5, serial_c);
            break :blk addSerialVariant(b, variant_options, serial_c, "ipmitool-serial-c");
        };
        const zig_tool = if (zig_selection[moduleIndex("serial-basic")] and
            zig_selection[moduleIndex("serial-terminal")]) ipmitool else blk: {
            variant_options.system_libs = withLibcrypto(b, base_libs, openssl, internal_md5, serial_zig);
            break :blk addSerialVariant(b, variant_options, serial_zig, "ipmitool-serial-zig");
        };
        const serial_run = b.addSystemCommand(&.{ "python3", "tests/transport/serial_test.py" });
        serial_run.addFileArg(oracle.getEmittedBin());
        serial_run.addFileArg(zig_tool.getEmittedBin());
        const serial_step = b.step("test-serial", "PTY parity tests for both serial modes");
        serial_step.dependOn(&serial_run.step);
        test_step.dependOn(serial_step);
    }
}

/// One run of the golden CLI suite against `exe`.
///
/// Extra arguments are forwarded, so `zig build test -- --filter sdr`,
/// `zig build test-golden -- --update` and `-- -v` all work.
fn addGolden(
    b: *std.Build,
    golden_exe: *std.Build.Step.Compile,
    exe: *std.Build.Step.Compile,
    work_dir: ?[]const u8,
    zig_gendev: bool,
    zig_deviations: bool,
    zig_shell_deviations: bool,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(golden_exe);
    run.setName(b.fmt("golden {s}", .{exe.name}));
    run.addArg("--tests-dir");
    run.addDirectoryArg(b.path("tests"));
    // Only used to locate `src/ipmitool.c` for the command coverage check.
    // Passed as a plain path so the step does not take a hash dependency on
    // the entire work tree; `src/ipmitool.c` is a source of `exe`, so a change
    // to the command table already invalidates this step through the binary.
    run.addArgs(&.{ "--repo", b.build_root.path orelse "." });
    run.addArg("--binary");
    run.addFileArg(exe.getEmittedBin());
    if (zig_deviations) run.addArg("--zig-deviations");
    if (zig_shell_deviations) run.addArg("--zig-shell-deviations");
    // A private scratch root per run: the default and the Zig-swapped suites
    // are independent steps and the build runner may execute them at the same
    // time.  `tmpPath` lives in the cache and is cleaned up on success.
    run.addArg("--work-dir");
    if (work_dir) |path| {
        run.addArg(path);
        run.has_side_effects = true;
    } else {
        run.addDirectoryArg(b.tmpPath());
    }
    if (zig_gendev) run.addArg("--zig-gendev");
    if (b.args) |args| run.addArgs(args);
    run.expectExitCode(0);
    return run;
}

fn fruIndex() usize {
    for (zig_modules, 0..) |module, index| {
        if (std.mem.eql(u8, module.name, "fru")) return index;
    }
    unreachable;
}

fn addFruOemGolden(
    b: *std.Build,
    golden_exe: *std.Build.Step.Compile,
    exe: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(golden_exe);
    run.setName(b.fmt("golden Zig FRU OEM {s}", .{exe.name}));
    run.addArg("--tests-dir");
    run.addDirectoryArg(b.path("tests/zig-fru"));
    run.addArgs(&.{ "--repo", b.build_root.path orelse ".", "--binary" });
    run.addFileArg(exe.getEmittedBin());
    run.addArg("--work-dir");
    run.addDirectoryArg(b.tmpPath());
    run.addArg("--allow-uncovered");
    run.expectExitCode(0);
    return run;
}

/// One run of the transport fixture suite against `exe`.
///
/// `record` switches the harness from comparing to rewriting the fixtures;
/// that step has side effects on the source tree and is reachable only through
/// `zig build gen-transport-fixtures`.
fn addTransport(
    b: *std.Build,
    transport_exe: *std.Build.Step.Compile,
    exe: *std.Build.Step.Compile,
    record: bool,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(transport_exe);
    run.setName(b.fmt("{s} {s}", .{ if (record) "record transport" else "transport", exe.name }));
    run.addArg("--binary");
    run.addFileArg(exe.getEmittedBin());
    run.addArg("--iana");
    run.addFileArg(b.path("tests/fixtures/iana/enterprise-numbers"));
    run.addArg("--sensor-fixture");
    run.addFileArg(b.path("tests/fixtures/sensor/full_bridged.hex"));
    run.addArg("--work-dir");
    run.addDirectoryArg(b.tmpPath());
    if (record) {
        // A plain path, not `addDirectoryArg`: this writes into the source
        // tree on purpose, so it must not be a cached, hashed input.
        run.addArgs(&.{ "--fixtures-dir", b.pathFromRoot("tests/transport/fixtures"), "--update" });
        run.has_side_effects = true;
    } else {
        run.addArg("--fixtures-dir");
        run.addDirectoryArg(b.path("tests/transport/fixtures"));
    }
    if (b.args) |args| run.addArgs(args);
    run.expectExitCode(0);
    return run;
}

const VectorGeneratorOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_c: bool,
    config_h: *std.Build.Step.ConfigHeader,
    default_intf: []const u8,
    flags: []const []const u8,
};

/// `zig build gen-crypto-vectors`: rebuild the crypto parity fixtures.
///
/// Links `tests/crypto/gen_vectors.c` against the *original* OpenSSL-backed
/// crypto translation units and dumps every input/output pair the Zig ports
/// have to reproduce into `tests/crypto/vectors/`.  The fixtures are committed;
/// this step only exists so they can be re-derived from the C.
///
/// It is not reachable from `zig build` or `zig build test` on purpose: it is
/// the last consumer of libcrypto in the tree, and CI must not need OpenSSL to
/// build or test ipmitool once the ports are selected.
fn addCryptoVectorGenerator(b: *std.Build, options: VectorGeneratorOptions) void {
    const mod = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .sanitize_c = if (options.sanitize_c) .full else .off,
    });
    configure(b, mod, options.config_h, options.default_intf);
    mod.addCSourceFiles(.{
        .root = b.path("tests/crypto"),
        .files = &.{"gen_vectors.c"},
        // The generator deliberately shadows a handful of ipmitool symbols and
        // is not part of the product, so the pedantic warning set is dropped.
        .flags = &.{"-std=gnu11"},
        .language = .c,
    });
    for (crypto_vector_sources) |source| {
        const slash = std.mem.lastIndexOfScalar(u8, source, '/').?;
        mod.addCSourceFiles(.{
            .root = b.path(source[0..slash]),
            .files = &.{source[slash + 1 ..]},
            .flags = options.flags,
            .language = .c,
        });
    }
    mod.linkSystemLibrary("crypto", .{});

    const exe = b.addExecutable(.{ .name = "gen-crypto-vectors", .root_module = mod });
    const run = b.addRunArtifact(exe);
    run.addArg(b.pathFromRoot("tests/crypto/vectors"));
    // Some distributions ship an openssl.cnf that activates a provider without
    // MD5 (Azure Linux routes libcrypto through SymCrypt, which refuses
    // HMAC-MD5).  An empty config selects OpenSSL's own default provider, so
    // the fixtures are the same wherever they are regenerated.
    run.setEnvironmentVariable("OPENSSL_CONF", "/dev/null");
    run.has_side_effects = true;
    b.step(
        "gen-crypto-vectors",
        "Regenerate tests/crypto/vectors from the OpenSSL-backed C sources",
    ).dependOn(&run.step);
}

/// Fixture files the crypto parity tests `@embedFile`.
///
/// They live under `tests/` next to the generator that produced them rather
/// than under `src/`, so they are exposed as named imports instead of by a
/// relative path out of the module root.
const crypto_vector_fixtures = [_][]const u8{
    "md5",     "auth",      "hmac", "aes_cbc",
    "payload", "integrity", "rakp", "aborts",
};

fn addCryptoVectors(b: *std.Build, mod: *std.Build.Module) void {
    for (crypto_vector_fixtures) |name| {
        mod.addAnonymousImport(b.fmt("crypto_vectors_{s}", .{name}), .{
            .root_source_file = b.path(b.fmt("tests/crypto/vectors/{s}.txt", .{name})),
        });
    }
}

const SwappedOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_c: bool,
    config_h: *std.Build.Step.ConfigHeader,
    default_intf: []const u8,
    flags: []const []const u8,
    plugins_enabled: []const bool,
    bridge_mod: *std.Build.Module,
    have_crypto_sha256: bool,
    system_libs: []const []const u8,
};

/// An `ipmitool` with every entry of `zig_modules` served by Zig, built only
/// for `zig build test-golden`.  Nothing installs it.
///
/// This mirrors the main build rather than refactoring it, so that adding a
/// module stays a one-entry change to `zig_modules` and does not touch here.
fn addSwappedTool(b: *std.Build, options: SwappedOptions) *std.Build.Step.Compile {
    return addSelectedTool(b, options, &all_selected, "ipmitool-zig");
}

fn addSelectedTool(
    b: *std.Build,
    options: SwappedOptions,
    selection: []const bool,
    name: []const u8,
) *std.Build.Step.Compile {
    const core_mod = b.createModule(.{
        .root_source_file = emptyCoreRoot(b, selection),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .sanitize_c = if (options.sanitize_c) .full else .off,
    });
    configure(b, core_mod, options.config_h, options.default_intf);
    addSources(b, core_mod, lib_sources, options.flags, selection);
    addSources(b, core_mod, intf_sources, options.flags, selection);
    for (plugins, 0..) |plugin, i| {
        if (!options.plugins_enabled[i]) continue;
        addSources(b, core_mod, plugin.sources, options.flags, selection);
    }
    const core = b.addLibrary(.{
        .name = "ipmitool_core_zig",
        .linkage = .static,
        .root_module = core_mod,
    });

    const zig_lib: ?*std.Build.Step.Compile = if (anySelected(selection)) blk: {
        // A selected USB port needs SG_IO even with its interface disabled.
        // Do not expose SCSI headers to ordinary builds without that port.
        const export_bridge_mod = if (selection[moduleIndex("usb")] and
            !options.plugins_enabled[pluginIndex("usb")])
        bridge_blk: {
            const bridge = b.addTranslateC(.{
                .root_source_file = b.path(zig_bridge_header),
                .target = options.target,
                .optimize = options.optimize,
                .link_libc = true,
            });
            bridge.addConfigHeader(options.config_h);
            bridge.addIncludePath(b.path("include"));
            bridge.defineCMacro("HAVE_CONFIG_H", "1");
            bridge.defineCMacro("DEFAULT_INTF", b.fmt("\"{s}\"", .{options.default_intf}));
            bridge.defineCMacro("IPMITOOL_ZIG_USB", "1");
            break :bridge_blk bridge.createModule();
        } else options.bridge_mod;
        const zig_options = b.addOptions();
        zig_options.addOption([]const []const u8, "zig_modules", selectedZigModules(b, selection));
        zig_options.addOption(bool, "have_crypto_sha256", options.have_crypto_sha256);
        const exports_mod = b.createModule(.{
            .root_source_file = b.path(zig_root ++ "/exports.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
            .sanitize_c = if (options.sanitize_c) .full else .off,
        });
        exports_mod.addImport("ipmi_c", export_bridge_mod);
        exports_mod.addImport("build_options", zig_options.createModule());
        addZigCShims(
            b,
            exports_mod,
            options.config_h,
            options.default_intf,
            options.flags,
            selection,
        );
        break :blk b.addLibrary(.{
            .name = b.fmt("ipmitool_zig_{s}", .{name}),
            .linkage = .static,
            .root_module = exports_mod,
        });
    } else null;

    return addTool(b, .{
        .name = name,
        .sources = if (std.mem.startsWith(u8, name, "ipmievd")) ipmievd_sources else ipmitool_sources,
        .target = options.target,
        .optimize = options.optimize,
        .sanitize_c = options.sanitize_c,
        .config_h = options.config_h,
        .default_intf = options.default_intf,
        .flags = options.flags,
        .core = core,
        .bridge_mod = options.bridge_mod,
        .have_crypto_sha256 = options.have_crypto_sha256,
        .zig_lib = zig_lib,
        .zig_selection = selection,
        .system_libs = options.system_libs,
    });
}

fn addSerialVariant(b: *std.Build, options: SwappedOptions, selection: []const bool, name: []const u8) *std.Build.Step.Compile {
    const core_mod = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .sanitize_c = if (options.sanitize_c) .full else .off,
    });
    configure(b, core_mod, options.config_h, options.default_intf);
    addSources(b, core_mod, lib_sources, options.flags, selection);
    addSources(b, core_mod, intf_sources, options.flags, selection);
    for (plugins, 0..) |plugin, i| {
        if (options.plugins_enabled[i]) addSources(b, core_mod, plugin.sources, options.flags, selection);
    }
    const core = b.addLibrary(.{
        .name = "ipmitool_core_serial_variant",
        .linkage = .static,
        .root_module = core_mod,
    });
    const zig_lib: ?*std.Build.Step.Compile = if (anySelected(selection)) blk: {
        const zig_options = b.addOptions();
        zig_options.addOption([]const []const u8, "zig_modules", selectedZigModules(b, selection));
        zig_options.addOption(bool, "have_crypto_sha256", options.have_crypto_sha256);
        const mod = b.createModule(.{
            .root_source_file = b.path(zig_root ++ "/exports.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
        });
        mod.addImport("ipmi_c", options.bridge_mod);
        mod.addImport("build_options", zig_options.createModule());
        addZigCShims(b, mod, options.config_h, options.default_intf, options.flags, selection);
        break :blk b.addLibrary(.{ .name = "ipmitool_serial_variant_zig", .linkage = .static, .root_module = mod });
    } else null;
    return addTool(b, .{
        .name = name,
        .sources = ipmitool_sources,
        .target = options.target,
        .optimize = options.optimize,
        .sanitize_c = options.sanitize_c,
        .config_h = options.config_h,
        .default_intf = options.default_intf,
        .flags = options.flags,
        .core = core,
        .bridge_mod = options.bridge_mod,
        .have_crypto_sha256 = options.have_crypto_sha256,
        .zig_lib = zig_lib,
        .zig_selection = selection,
        .system_libs = options.system_libs,
    });
}

fn moduleIndex(comptime name: []const u8) usize {
    return comptime blk: {
        for (zig_modules, 0..) |module, i| {
            if (std.mem.eql(u8, module.name, name)) break :blk i;
        }
        @compileError("unknown Zig module");
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Renders `#define NAME 1` when set and `/* #undef NAME */` when not, which is
/// what autoconf's `AC_DEFINE` produces.
fn flag(value: bool) ?u8 {
    return if (value) 1 else null;
}

fn pluginIndex(comptime name: []const u8) usize {
    return comptime blk: {
        for (plugins, 0..) |plugin, i| {
            if (std.mem.eql(u8, plugin.name, name)) break :blk i;
        }
        @compileError("unknown plugin: " ++ name);
    };
}

fn validateDefaultIntf(b: *std.Build, name: []const u8, enabled: []const bool) void {
    for (plugins, 0..) |plugin, i| {
        if (std.mem.eql(u8, plugin.name, name)) {
            if (!enabled[i]) {
                std.debug.print(
                    "error: cannot set '{s}' as the default interface; -Dintf-{s} is disabled\n",
                    .{ name, name },
                );
                std.process.exit(1);
            }
            return;
        }
    }
    std.debug.print("error: unknown default interface '{s}'\n", .{name});
    std.process.exit(1);
    _ = b;
}

fn addSources(
    b: *std.Build,
    mod: *std.Build.Module,
    set: CSourceSet,
    flags: []const []const u8,
    zig_selection: []const bool,
) void {
    var files: std.ArrayList([]const u8) = .empty;
    for (set.files) |file| {
        const path = b.fmt("{s}/{s}", .{ set.dir, file });
        if (replacedByZig(path, zig_selection)) continue;
        if (allSelected(zig_selection)) {
            std.debug.print("error: all-selected tool still compiles {s}\n", .{path});
            std.process.exit(1);
        }
        files.append(b.allocator, file) catch @panic("OOM");
    }
    if (files.items.len == 0) return;
    mod.addCSourceFiles(.{
        .root = b.path(set.dir),
        .files = files.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .flags = flags,
        .language = .c,
    });
}

fn emptyCoreRoot(b: *std.Build, selection: []const bool) ?std.Build.LazyPath {
    if (!allSelected(selection)) return null;
    // The final C-to-Zig replacement can leave the core archive without an object.
    return b.addWriteFiles().add("empty-core.zig", "pub export var ipmitool_zig_empty_core: u8 = 0;\n");
}

/// True when `path` is a C translation unit a selected Zig module replaces.
/// Keeping the `.c` out of the compile is what makes the swap a link-time
/// substitution instead of a duplicate-symbol error.
/// A selection with every registered module enabled, i.e. what the golden
/// suite's second binary and `zig build test` use.
const all_selected: [zig_modules.len]bool = @splat(true);

/// Append `crypto` to `base` when a C translation unit still needs it.
///
/// This is the whole libcrypto removal: the flag follows the source inventory
/// instead of the `-Dopenssl` switch, so the dependency disappears exactly when
/// the last C caller is replaced rather than when someone remembers to edit the
/// link line.
fn withLibcrypto(
    b: *std.Build,
    base: []const []const u8,
    openssl: bool,
    internal_md5: bool,
    zig_selection: []const bool,
) []const []const u8 {
    if (!openssl) return base;

    var needed = false;
    for (libcrypto_c_sources) |source| {
        // auth.c only reaches libcrypto for MD5, and `-Dinternal-md5` sends it
        // to the bundled implementation instead.
        if (internal_md5 and std.mem.eql(u8, source, "src/plugins/lan/auth.c")) continue;
        if (!replacedByZig(source, zig_selection)) needed = true;
    }
    if (!needed) return base;

    var libs: std.ArrayList([]const u8) = .empty;
    libs.appendSlice(b.allocator, base) catch @panic("OOM");
    libs.append(b.allocator, "crypto") catch @panic("OOM");
    return libs.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn replacedByZig(path: []const u8, zig_selection: []const bool) bool {
    for (zig_modules, 0..) |module, i| {
        if (!zig_selection[i]) continue;
        if (std.mem.eql(u8, module.replaces, path)) return true;
        for (module.also_replaces) |extra| {
            if (std.mem.eql(u8, extra, path)) return true;
        }
    }
    return false;
}

fn moduleSelected(name: []const u8, zig_selection: []const bool) bool {
    for (zig_modules, zig_selection) |module, selected| {
        if (selected and std.mem.eql(u8, module.name, name)) return true;
    }
    return false;
}

/// Adds the C shims needed by the selected modules to the replacement library.
fn addZigCShims(
    b: *std.Build,
    mod: *std.Build.Module,
    config_h: *std.Build.Step.ConfigHeader,
    default_intf: []const u8,
    flags: []const []const u8,
    zig_selection: []const bool,
) void {
    var files: std.ArrayList([]const u8) = .empty;
    for (zig_modules, 0..) |module, i| {
        if (!zig_selection[i]) continue;
        for (module.c_shims) |shim| {
            // A fully selected tool has no C logger callers; mixed selections
            // still need the C-variadic ABI for their remaining C sources.
            if (allSelected(zig_selection) and
                std.mem.eql(u8, shim, "src/zig/util/log_varargs.c")) continue;
            files.append(b.allocator, shim) catch @panic("OOM");
        }
    }
    if (files.items.len == 0) return;

    configure(b, mod, config_h, default_intf);
    mod.addCSourceFiles(.{
        .files = files.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .flags = flags,
        .language = .c,
    });
}

/// `-Dzig-modules` value list for `zig build --help`.
fn zigModuleNames() []const u8 {
    comptime {
        var names: []const u8 = "";
        for (zig_modules, 0..) |module, i| {
            names = names ++ (if (i == 0) "" else ", ") ++ module.name;
        }
        return if (names.len == 0) "(none yet)" else names;
    }
}

/// Parses `-Dzig-modules=a,b` or `-Dzig-modules=all`, rejecting unknown names.
fn parseZigModules(b: *std.Build, value: ?[]const u8) []const bool {
    const selection = b.allocator.alloc(bool, zig_modules.len) catch @panic("OOM");
    @memset(selection, false);
    const list = value orelse return selection;

    var it = std.mem.tokenizeAny(u8, list, ", \t");
    outer: while (it.next()) |name| {
        if (std.mem.eql(u8, name, "all")) {
            @memset(selection, true);
            continue :outer;
        }
        for (zig_modules, 0..) |module, i| {
            if (std.mem.eql(u8, module.name, name)) {
                selection[i] = true;
                continue :outer;
            }
        }
        std.debug.print(
            \\error: unknown -Dzig-modules entry '{s}'.
            \\
            \\  Valid module names are: all, {s}
            \\
            \\  Each name selects the Zig implementation of one C translation unit;
            \\  see doc/zig-migration/interop-seams.md for the list and for how to
            \\  add a new one.
            \\
        , .{ name, comptime zigModuleNames() });
        std.process.exit(1);
    }
    return selection;
}

fn anySelected(zig_selection: []const bool) bool {
    for (zig_selection) |selected| {
        if (selected) return true;
    }
    return false;
}

fn allSelected(zig_selection: []const bool) bool {
    for (zig_selection) |selected| {
        if (!selected) return false;
    }
    return true;
}

/// Selected module names, passed to `src/zig/exports.zig` as build options.
fn selectedZigModules(b: *std.Build, zig_selection: []const bool) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (zig_modules, 0..) |module, i| {
        if (zig_selection[i]) names.append(b.allocator, module.name) catch @panic("OOM");
    }
    return names.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// Include paths and macros every translation unit needs.
fn configure(
    b: *std.Build,
    mod: *std.Build.Module,
    config_h: *std.Build.Step.ConfigHeader,
    default_intf: []const u8,
) void {
    mod.addConfigHeader(config_h);
    mod.addIncludePath(b.path("include"));
    mod.addCMacro("HAVE_CONFIG_H", "1");
    // src/plugins/Makefile.am: libintf_la_CFLAGS
    mod.addCMacro("DEFAULT_INTF", b.fmt("\"{s}\"", .{default_intf}));
}

const ToolOptions = struct {
    name: []const u8,
    sources: CSourceSet,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_c: bool,
    config_h: *std.Build.Step.ConfigHeader,
    default_intf: []const u8,
    flags: []const []const u8,
    core: *std.Build.Step.Compile,
    bridge_mod: *std.Build.Module,
    have_crypto_sha256: bool,
    zig_lib: ?*std.Build.Step.Compile,
    zig_selection: []const bool,
    system_libs: []const []const u8,
};

fn addEvdImports(
    b: *std.Build,
    mod: *std.Build.Module,
    bridge_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    selection: ?[]const bool,
    have_crypto_sha256: bool,
) void {
    const options = b.addOptions();
    options.addOption([]const []const u8, "zig_modules", if (selection) |selected| selectedZigModules(b, selected) else &.{});
    options.addOption(bool, "have_crypto_sha256", have_crypto_sha256);
    const options_mod = options.createModule();
    mod.addImport("build_options", options_mod);
    const headers = b.createModule(.{
        .root_source_file = b.path("src/zig/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    headers.addImport("ipmi_c", bridge_mod);
    headers.addImport("build_options", options_mod);
    mod.addImport("ipmi_zig", headers);
}

fn addTool(b: *std.Build, options: ToolOptions) *std.Build.Step.Compile {
    const zig_evd = std.mem.startsWith(u8, options.name, "ipmievd") and
        replacedByZig("src/ipmievd.c", options.zig_selection);
    const zig_cli = replacedByZig("src/ipmitool.c", options.zig_selection) and
        std.mem.startsWith(u8, options.name, "ipmitool");
    const mod = b.createModule(.{
        .root_source_file = if (zig_evd) b.path("src/zig/front/ipmievd.zig") else if (zig_cli) b.path(zig_root ++ "/cli/tool.zig") else null,
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .sanitize_c = if (options.sanitize_c) .full else .off,
    });
    configure(b, mod, options.config_h, options.default_intf);
    if (zig_evd) {
        mod.addImport("ipmi_c", options.bridge_mod);
        addEvdImports(b, mod, options.bridge_mod, options.target, options.optimize, options.zig_selection, options.have_crypto_sha256);
    }
    if (zig_cli) mod.addImport("ipmi_c", options.bridge_mod);
    addSources(b, mod, options.sources, options.flags, options.zig_selection);
    mod.linkLibrary(options.core);
    // Listed after the C archive so the linker resolves the symbols the
    // remaining C still references out of the Zig replacements.
    if (options.zig_lib) |zig_lib| mod.linkLibrary(zig_lib);
    for (options.system_libs) |lib| mod.linkSystemLibrary(lib, .{});
    return b.addExecutable(.{ .name = options.name, .root_module = mod });
}

const Substitution = struct {
    name: []const u8,
    value: []const u8,
};

/// Expands `@NAME@` placeholders the way `AC_CONFIG_FILES` does. Used for the
/// `doc/*.in` man page templates, which cannot go through `addConfigHeader`
/// because that prepends a C comment.
fn substitute(
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,
    in_path: []const u8,
    out_name: []const u8,
    subs: []const Substitution,
) std.Build.LazyPath {
    const gpa = b.allocator;
    var text = b.build_root.handle.readFileAlloc(
        b.graph.io,
        in_path,
        gpa,
        .limited(4 * 1024 * 1024),
    ) catch |err| std.debug.panic("unable to read '{s}': {s}", .{ in_path, @errorName(err) });
    for (subs) |sub| {
        const needle = b.fmt("@{s}@", .{sub.name});
        text = std.mem.replaceOwned(u8, gpa, text, needle, sub.value) catch @panic("OOM");
    }
    return wf.add(out_name, text);
}

/// Reproduces `./csv-revision`: `1.8.19` plus the `.<rev>.<hash>` suffix from
/// `git describe`. Falls back to the plain base version outside a git checkout,
/// so that packaged tarballs and CI without git still build.
fn detectVersion(b: *std.Build) []const u8 {
    // `runAllowFail` only writes `code` when the child fails, and reports any
    // failure as an error, so the error path is the only one that matters.
    var code: u8 = 0;
    const raw = b.runAllowFail(
        &.{ "git", "-C", b.pathFromRoot("."), "describe", "--first-parent", "--tags" },
        &code,
        .ignore,
    ) catch return base_version;

    const described = std.mem.trim(u8, raw, " \t\r\n");
    var it = std.mem.splitScalar(u8, described, '-');
    _ = it.next(); // tag
    const rev = it.next() orelse return base_version;
    const hash = it.next() orelse return base_version;
    if (rev.len == 0 or hash.len == 0) return base_version;
    return b.fmt("{s}.{s}.{s}", .{ base_version, rev, hash });
}

/// Splits a comma separated `-D` option value into individual entries.
fn splitList(b: *std.Build, list: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, list, ", \t");
    while (it.next()) |item| out.append(b.allocator, b.dupe(item)) catch @panic("OOM");
    return out.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn nonEmpty(list: []const []const u8) ?[]const []const u8 {
    return if (list.len == 0) null else list;
}

/// Standard prefixes searched for `readline/readline.h` when pkg-config has no
/// answer, mirroring autoconf's `AC_SEARCH_LIBS` fallback.
const readline_prefixes = [_][]const u8{
    "/usr",
    "/usr/local",
    "/opt/homebrew",
    "/opt/local",
};

/// Mirrors `PKG_CHECK_MODULES([READLINE], [readline])` with autoconf's
/// `AC_SEARCH_LIBS([readline], [readline edit])` fallback: ask pkg-config
/// first, then look for the header under the usual prefixes.
/// Returns the libraries to link, or null when readline is unavailable.
fn detectReadline(b: *std.Build) ?[]const []const u8 {
    var code: u8 = 0;
    if (b.runAllowFail(&.{ "pkg-config", "--libs", "readline" }, &code, .ignore)) |out| {
        var libs: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, out, " \t\r\n");
        while (it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "-l")) {
                libs.append(b.allocator, b.dupe(arg[2..])) catch @panic("OOM");
            }
        }
        if (libs.items.len > 0) return libs.toOwnedSlice(b.allocator) catch @panic("OOM");
    } else |_| {}

    const io = b.graph.io;
    for (b.search_prefixes.items) |prefix| {
        if (hasReadlineHeader(b, io, prefix)) return &.{"readline"};
    }
    for (readline_prefixes) |prefix| {
        if (hasReadlineHeader(b, io, prefix)) return &.{"readline"};
    }
    return null;
}

fn hasReadlineHeader(b: *std.Build, io: std.Io, prefix: []const u8) bool {
    const path = b.fmt("{s}/include/readline/readline.h", .{prefix});
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}
