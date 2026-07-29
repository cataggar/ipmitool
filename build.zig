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
// the same C symbols.  Adding a port means one entry here plus one guarded
// `@import` in `src/zig/exports.zig`.
//
// See doc/zig-migration/interop-seams.md.
// ---------------------------------------------------------------------------

/// One C translation unit that has a Zig implementation available.
const ZigModule = struct {
    /// Name used in `-Dzig-modules=<name>`.
    name: []const u8,
    /// C translation unit it replaces, relative to the build root.
    replaces: []const u8,
    /// Zig implementation, for documentation and `zig build --help`.
    implementation: []const u8,
};

const zig_modules = [_]ZigModule{
    .{
        .name = "oem",
        .replaces = "lib/ipmi_oem.c",
        .implementation = "src/zig/cmd/oem.zig",
    },
    .{
        .name = "strings",
        .replaces = "lib/ipmi_strings.c",
        .implementation = "src/zig/util/strings.zig",
    },
};

/// Root of the Zig source tree.
const zig_root = "src/zig";

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
        .name = "imb",
        .macro = "IPMI_INTF_IMB",
        .sources = .{ .dir = "src/plugins/imb", .files = &.{ "imbapi.c", "imb.c" } },
        .default = .linux_only,
        .help = "Intel IMB driver interface",
    },
    .{
        .name = "lipmi",
        .macro = "IPMI_INTF_LIPMI",
        .sources = .{ .dir = "src/plugins/lipmi", .files = &.{"lipmi.c"} },
        .default = .off,
        .help = "Solaris 9 x86 IPMI interface (needs <sys/lipmi/lipmi_intf.h>)",
    },
    .{
        .name = "bmc",
        .macro = "IPMI_INTF_BMC",
        .sources = .{ .dir = "src/plugins/bmc", .files = &.{"bmc.c"} },
        .default = .off,
        .help = "Solaris 10 x86 BMC interface (needs <sys/stropts.h>)",
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
        .name = "free",
        .macro = "IPMI_INTF_FREE",
        .sources = .{ .dir = "src/plugins/free", .files = &.{"free.c"} },
        .default = .off,
        .system_libs = &.{"freeipmi"},
        .help = "FreeIPMI interface (requires libfreeipmi)",
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
    .{
        .name = "dbus",
        .macro = "IPMI_INTF_DBUS",
        .sources = .{ .dir = "src/plugins/dbus", .files = &.{"dbus.c"} },
        .default = .off,
        .system_libs = &.{"systemd"},
        .help = "OpenBMC dbus interface (requires libsystemd)",
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
        "Enable the readline-based IPMI shell; requires libreadline [default=true]",
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
                "available: {s} [default=none]",
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

    // lanplus is the only component that hard-requires libcrypto.
    const lanplus_index = pluginIndex("lanplus");
    if (enabled[lanplus_index] and !openssl) {
        std.debug.print(
            "warning: -Dintf-lanplus requires libcrypto; disabling it because -Dopenssl=false\n",
            .{},
        );
        enabled[lanplus_index] = false;
    }

    // configure.ac errors out when --enable-ipmishell is requested without
    // readline. Do the same instead of silently dropping the `shell` command,
    // which would make the binary diverge from the autotools baseline.
    const readline_libs: []const []const u8 = if (!ipmishell)
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
        .IPMI_INTF_IMB = flag(enabled[pluginIndex("imb")]),
        .IPMI_INTF_LIPMI = flag(enabled[pluginIndex("lipmi")]),
        .IPMI_INTF_BMC = flag(enabled[pluginIndex("bmc")]),
        .IPMI_INTF_LAN = flag(enabled[pluginIndex("lan")]),
        .IPMI_INTF_LANPLUS = flag(enabled[pluginIndex("lanplus")]),
        .IPMI_INTF_FREE = flag(enabled[pluginIndex("free")]),
        .IPMI_INTF_SERIAL = flag(enabled[pluginIndex("serial")]),
        .IPMI_INTF_DUMMY = flag(enabled[pluginIndex("dummy")]),
        .IPMI_INTF_USB = flag(enabled[pluginIndex("usb")]),
        .IPMI_INTF_DBUS = flag(enabled[pluginIndex("dbus")]),
        .ENABLE_INTF_OPEN_DUAL_BRIDGE = flag(false),

        // FreeIPMI ABI variants; only 0.6.0+ is still realistic.
        .IPMI_INTF_FREE_0_3_0 = flag(false),
        .IPMI_INTF_FREE_0_4_0 = flag(false),
        .IPMI_INTF_FREE_0_5_0 = flag(false),
        .IPMI_INTF_FREE_0_6_0 = flag(enabled[pluginIndex("free")]),
        .IPMI_INTF_FREE_BRIDGING = flag(enabled[pluginIndex("free")]),

        // Misc feature switches
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
    const bridge_mod = bridge.createModule();

    const zig_options = b.addOptions();
    zig_options.addOption([]const []const u8, "zig_modules", selectedZigModules(b, zig_selection));

    const zig_lib: ?*std.Build.Step.Compile = if (anySelected(zig_selection)) blk: {
        const mod = b.createModule(.{
            .root_source_file = b.path(zig_root ++ "/exports.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addImport("ipmi_c", bridge_mod);
        mod.addImport("build_options", zig_options.createModule());
        break :blk b.addLibrary(.{
            .name = "ipmitool_zig",
            .linkage = .static,
            .root_module = mod,
        });
    } else null;

    // System libraries are attached to the executables rather than to the
    // static archive: a `.a` cannot usefully carry shared objects.
    var system_libs: std.ArrayList([]const u8) = .empty;
    // lib/Makefile.am: libipmitool_la_LIBADD = -lm
    if (!is_windows) system_libs.append(b.allocator, "m") catch @panic("OOM");
    if (openssl) system_libs.append(b.allocator, "crypto") catch @panic("OOM");
    if (ipmishell) {
        for (readline_libs) |lib| system_libs.append(b.allocator, lib) catch @panic("OOM");
    }
    for (plugins, 0..) |plugin, i| {
        if (!enabled[i]) continue;
        for (plugin.system_libs) |lib| {
            if (std.mem.eql(u8, lib, "crypto")) continue;
            system_libs.append(b.allocator, lib) catch @panic("OOM");
        }
    }
    const libs = system_libs.toOwnedSlice(b.allocator) catch @panic("OOM");

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

    // -- `zig build test` ----------------------------------------------------
    //
    // Smoke tests, the Zig/C ABI parity assertions, and the golden CLI suite.

    const test_step = b.step("test", "Run the build smoke tests");

    // Compiling `src/zig/root.zig` runs every `comptime` layout assertion in
    // the header ports, so this fails the build when a C header and its Zig
    // mirror drift apart.  Nothing here is exported, so the test binary needs
    // no C objects.
    const abi_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_mod.addImport("ipmi_c", bridge_mod);
    const abi_tests = b.addTest(.{ .root_module = abi_mod });
    test_step.dependOn(&b.addRunArtifact(abi_tests).step);

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

    const golden_step = b.step("test-golden", "Run the golden CLI test suite");
    golden_step.dependOn(&addGolden(b, golden_exe, ipmitool).step);

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
            .system_libs = libs,
        });
        golden_step.dependOn(&addGolden(b, golden_exe, swapped).step);
    }

    test_step.dependOn(golden_step);
}

/// One run of the golden CLI suite against `exe`.
///
/// Extra arguments are forwarded, so `zig build test -- --filter sdr`,
/// `zig build test-golden -- --update` and `-- -v` all work.
fn addGolden(
    b: *std.Build,
    golden_exe: *std.Build.Step.Compile,
    exe: *std.Build.Step.Compile,
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
    // A private scratch root per run: the default and the Zig-swapped suites
    // are independent steps and the build runner may execute them at the same
    // time.  `tmpPath` lives in the cache and is cleaned up on success.
    run.addArg("--work-dir");
    run.addDirectoryArg(b.tmpPath());
    if (b.args) |args| run.addArgs(args);
    run.expectExitCode(0);
    return run;
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
    system_libs: []const []const u8,
};

/// An `ipmitool` with every entry of `zig_modules` served by Zig, built only
/// for `zig build test-golden`.  Nothing installs it.
///
/// This mirrors the main build rather than refactoring it, so that adding a
/// module stays a one-entry change to `zig_modules` and does not touch here.
fn addSwappedTool(b: *std.Build, options: SwappedOptions) *std.Build.Step.Compile {
    const selection = b.allocator.alloc(bool, zig_modules.len) catch @panic("OOM");
    @memset(selection, true);

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
        if (!options.plugins_enabled[i]) continue;
        addSources(b, core_mod, plugin.sources, options.flags, selection);
    }
    const core = b.addLibrary(.{
        .name = "ipmitool_core_zig",
        .linkage = .static,
        .root_module = core_mod,
    });

    const zig_options = b.addOptions();
    zig_options.addOption([]const []const u8, "zig_modules", selectedZigModules(b, selection));
    const exports_mod = b.createModule(.{
        .root_source_file = b.path(zig_root ++ "/exports.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    exports_mod.addImport("ipmi_c", options.bridge_mod);
    exports_mod.addImport("build_options", zig_options.createModule());
    const zig_lib = b.addLibrary(.{
        .name = "ipmitool_zig_all",
        .linkage = .static,
        .root_module = exports_mod,
    });

    return addTool(b, .{
        .name = "ipmitool-zig",
        .sources = ipmitool_sources,
        .target = options.target,
        .optimize = options.optimize,
        .sanitize_c = options.sanitize_c,
        .config_h = options.config_h,
        .default_intf = options.default_intf,
        .flags = options.flags,
        .core = core,
        .zig_lib = zig_lib,
        .zig_selection = selection,
        .system_libs = options.system_libs,
    });
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

/// True when `path` is a C translation unit a selected Zig module replaces.
/// Keeping the `.c` out of the compile is what makes the swap a link-time
/// substitution instead of a duplicate-symbol error.
fn replacedByZig(path: []const u8, zig_selection: []const bool) bool {
    for (zig_modules, 0..) |module, i| {
        if (zig_selection[i] and std.mem.eql(u8, module.replaces, path)) return true;
    }
    return false;
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

/// Parses `-Dzig-modules=a,b`, rejecting unknown names.
fn parseZigModules(b: *std.Build, value: ?[]const u8) []const bool {
    const selection = b.allocator.alloc(bool, zig_modules.len) catch @panic("OOM");
    @memset(selection, false);
    const list = value orelse return selection;

    var it = std.mem.tokenizeAny(u8, list, ", \t");
    outer: while (it.next()) |name| {
        for (zig_modules, 0..) |module, i| {
            if (std.mem.eql(u8, module.name, name)) {
                selection[i] = true;
                continue :outer;
            }
        }
        std.debug.print(
            \\error: unknown -Dzig-modules entry '{s}'.
            \\
            \\  Valid module names are: {s}
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
    zig_lib: ?*std.Build.Step.Compile,
    zig_selection: []const bool,
    system_libs: []const []const u8,
};

fn addTool(b: *std.Build, options: ToolOptions) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .sanitize_c = if (options.sanitize_c) .full else .off,
    });
    configure(b, mod, options.config_h, options.default_intf);
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
