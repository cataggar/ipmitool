//! Port of `src/plugins/ipmi_intf.c`: the transport registry, the session
//! parameter setters and the shared UDP socket helper.
//!
//! Selected with `zig build -Dzig-modules=intf`, which drops
//! `src/plugins/ipmi_intf.c` from the compile and links this module instead.
//!
//! This is the foundation the rest of Phase 4 (issue #10) sits on: every
//! transport is reached only through `ipmi_intf_table`, which this file owns,
//! and every `lan`/`lanplus` socket is opened by `ipmi_intf_socket_connect()`
//! below.  The transports themselves are still C; the vtable they plug into is
//! `intf.Intf`, whose layout is pinned against the C header in `intf.zig`.
//!
//! # Conditional compilation
//!
//! The C file is a thicket of `#ifdef IPMI_INTF_*`.  Those macros come from
//! `config.h`, so the `ipmi_c` bridge sees them too and `@hasDecl(c, "...")` is
//! the exact Zig equivalent: an interface is in the table here if and only if
//! its `.c` is in the build.  The `extern` declarations for the per-plugin
//! `struct ipmi_intf` instances live in `src/zig/ipmi_c.h` under the same
//! guards, in the same order.
//!
//! # Upstream behaviour preserved on purpose
//!
//! `ipmi_intf_socket_connect()` reuses `hints.ai_family` as a "connected" flag
//! after initialising it from `intf->ai_family`.  When the user forced a family
//! with `-4` or `-6` the flag is therefore already non-`AF_UNSPEC` on entry, so
//! the address loop always stops after the first candidate — even when
//! `connect()` failed — and the function reports success with an unconnected
//! socket.  Reproduced verbatim; see the comment at the loop tail.
//!
//! `ipmi_intf_session_set_password()` clears only `IPMI_AUTHCODE_BUFFER_SIZE`
//! of the `IPMI_AUTHCODE_BUFFER_SIZE + 1` byte buffer, and
//! `ipmi_intf_get_max_*_data_size()` narrow a `uint16_t` into an `int16_t`.
//! Both are copied as they stand.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const intf_mod = @import("intf.zig");
const log = @import("../util/log.zig");

const Intf = intf_mod.Intf;
const IntfSupport = intf_mod.IntfSupport;

/// `IPMI_DEFAULT_PAYLOAD_SIZE`.
const default_payload_size = 25;

// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

/// Names of the C `struct ipmi_intf` instances, in `ipmi_intf_table` order,
/// each paired with the `config.h` macro that gates it.
///
/// Keep this list identical to the `#ifdef` ladder in
/// `src/plugins/ipmi_intf.c`: the order decides both the `-h` interface list
/// and which entry `get_default_interface()` falls back to.
///
/// `imb`, `lipmi`, `bmc`, `free` and `dbus` are absent because this fork
/// removed those plugins; see `doc/zig-migration/dropped-transports.md`.
const registered = [_]struct { macro: []const u8, symbol: []const u8 }{
    .{ .macro = "IPMI_INTF_OPEN", .symbol = "ipmi_open_intf" },
    .{ .macro = "IPMI_INTF_LAN", .symbol = "ipmi_lan_intf" },
    .{ .macro = "IPMI_INTF_LANPLUS", .symbol = "ipmi_lanplus_intf" },
    .{ .macro = "IPMI_INTF_SERIAL", .symbol = "ipmi_serial_term_intf" },
    .{ .macro = "IPMI_INTF_SERIAL", .symbol = "ipmi_serial_bm_intf" },
    .{ .macro = "IPMI_INTF_DUMMY", .symbol = "ipmi_dummy_intf" },
    .{ .macro = "IPMI_INTF_USB", .symbol = "ipmi_usb_intf" },
};

/// Number of enabled entries plus the terminating null, matching the size the
/// C compiler gives `ipmi_intf_table[]`.
const table_len = blk: {
    var n = 1;
    for (registered) |entry| {
        if (@hasDecl(c, entry.macro)) n += 1;
    }
    break :blk n;
};

/// `struct ipmi_intf * ipmi_intf_table[]`, null terminated.
var ipmi_intf_table: [table_len]?*Intf = blk: {
    var table: [table_len]?*Intf = @splat(null);
    var n = 0;
    for (registered) |entry| {
        if (!@hasDecl(c, entry.macro)) continue;
        table[n] = @ptrCast(&@field(c, entry.symbol));
        n += 1;
    }
    const frozen = table;
    break :blk frozen;
};

/// `get_default_interface()`, over an arbitrary table.
///
/// Split out from the exported entry points so the unit tests below can drive
/// it with a synthetic table: `ipmi_intf_table` itself is built from the C
/// plugin globals, which the `zig build test` binary does not link.
///
/// The C comment says the "first entry" fallback is unreachable because
/// configure refuses a default that is not enabled, and `build.zig`'s
/// `validateDefaultIntf()` does the same; it is kept so the two builds agree.
fn defaultInterface(table: []const ?*Intf) ?*Intf {
    const default_intf_name: [*:0]const u8 = c.DEFAULT_INTF;
    for (table) |entry| {
        const candidate = entry orelse break;
        if (c.strcmp(default_intf_name, @ptrCast(&candidate.name)) == 0) {
            return candidate;
        }
    }
    return table[0];
}

/// Name lookup half of `ipmi_intf_load()`, without the `setup()` call.
fn findInterface(table: []const ?*Intf, name: [*:0]const u8) ?*Intf {
    for (table) |entry| {
        const candidate = entry orelse break;
        if (c.strcmp(name, @ptrCast(&candidate.name)) == 0) {
            return candidate;
        }
    }
    return null;
}

/// True when `intflist` marks `candidate` as supported.
///
/// The C keeps scanning after a hit rather than breaking out, so a name that
/// appears twice with conflicting `supported` flags is reported as supported
/// if *any* entry says so.  Kept as it stands.
fn isSupported(intflist: [*]const IntfSupport, candidate: *const Intf) bool {
    var found = false;
    var i: usize = 0;
    while (intflist[i].name) |name| : (i += 1) {
        if (c.strcmp(name, @ptrCast(&candidate.name)) == 0 and
            intflist[i].supported != 0)
        {
            found = true;
        }
    }
    return found;
}

/// `ipmi_intf_print()`: the `Interfaces:` block of `ipmitool -h`.
fn ipmiIntfPrint(intflist: ?[*]IntfSupport) callconv(.c) void {
    const def_intf = defaultInterface(&ipmi_intf_table);
    c.lprintf(log.Level.notice, "Interfaces:");

    for (ipmi_intf_table) |entry| {
        const candidate = entry orelse break;

        if (intflist) |list| {
            if (!isSupported(list, candidate)) continue;
        }

        c.lprintf(
            log.Level.notice,
            "\t%-12s  %s %s",
            @as([*c]const u8, @ptrCast(&candidate.name)),
            @as([*c]const u8, @ptrCast(&candidate.desc)),
            @as([*c]const u8, if (def_intf == candidate) "[default]" else ""),
        );
    }
    c.lprintf(log.Level.notice, "");
}

/// `ipmi_intf_load()`: look an interface up by name and run its `setup()`.
///
/// A null `name` selects the compiled-in default.  Returns null when the name
/// is unknown or when `setup()` failed.
fn ipmiIntfLoad(name: ?[*:0]u8) callconv(.c) ?*Intf {
    const i = if (name) |wanted|
        findInterface(&ipmi_intf_table, wanted) orelse return null
    else
        // The C dereferences the result unconditionally; the table is never
        // empty because `build.zig` rejects a default that is not enabled.
        defaultInterface(&ipmi_intf_table).?;

    if (i.setup) |setup| {
        if (setup(i) < 0) {
            // With no `-I` the C passes the null `name` straight to "%s" and
            // glibc renders "(null)"; kept, the message is observable.
            c.lprintf(log.Level.err, "Unable to setup interface %s", name);
            return null;
        }
    }
    return i;
}

// ---------------------------------------------------------------------------
// Session parameters
// ---------------------------------------------------------------------------

fn sessionSetHostname(intf: *Intf, hostname: ?[*:0]u8) callconv(.c) void {
    if (intf.ssn_params.hostname) |old| {
        c.free(old);
        intf.ssn_params.hostname = null;
    }
    const name = hostname orelse return;
    intf.ssn_params.hostname = @ptrCast(c.strdup(name));
}

fn sessionSetUsername(intf: *Intf, username: ?[*:0]u8) callconv(.c) void {
    @memset(&intf.ssn_params.username, 0);

    const name = username orelse return;
    const n = @min(c.strlen(name), 16);
    @memcpy(intf.ssn_params.username[0..n], name[0..n]);
}

fn sessionSetPassword(intf: *Intf, password: ?[*:0]u8) callconv(.c) void {
    // Only the first IPMI_AUTHCODE_BUFFER_SIZE bytes of the
    // IPMI_AUTHCODE_BUFFER_SIZE + 1 byte buffer, exactly as upstream.
    @memset(intf.ssn_params.authcode_set[0..intf_mod.authcode_buffer_size], 0);

    const pass = password orelse {
        intf.ssn_params.password = 0;
        return;
    };

    intf.ssn_params.password = 1;
    const n = @min(c.strlen(pass), intf_mod.authcode_buffer_size);
    @memcpy(intf.ssn_params.authcode_set[0..n], pass[0..n]);
}

fn sessionSetPrivlvl(intf: *Intf, level: u8) callconv(.c) void {
    intf.ssn_params.privlvl = level;
}

fn sessionSetLookupbit(intf: *Intf, lookupbit: u8) callconv(.c) void {
    intf.ssn_params.lookupbit = lookupbit;
}

fn sessionSetCipherSuiteId(
    intf: *Intf,
    cipher_suite_id: intf_mod.CipherSuiteId,
) callconv(.c) void {
    intf.ssn_params.cipher_suite_id = cipher_suite_id;
}

fn sessionSetSolEscapeChar(intf: *Intf, sol_escape_char: u8) callconv(.c) void {
    intf.ssn_params.sol_escape_char = sol_escape_char;
}

fn sessionSetKgkey(intf: *Intf, kgkey: [*]const u8) callconv(.c) void {
    @memcpy(&intf.ssn_params.kg, kgkey[0..intf_mod.kg_buffer_size]);
}

fn sessionSetPort(intf: *Intf, port: c_int) callconv(.c) void {
    intf.ssn_params.port = port;
}

fn sessionSetAuthtype(intf: *Intf, authtype: u8) callconv(.c) void {
    // Clear the password field if authtype NONE was specified.
    if (authtype == c.IPMI_SESSION_AUTHTYPE_NONE) {
        @memset(intf.ssn_params.authcode_set[0..intf_mod.authcode_buffer_size], 0);
        intf.ssn_params.password = 0;
    }

    intf.ssn_params.authtype_set = authtype;
}

fn sessionSetTimeout(intf: *Intf, timeout: u32) callconv(.c) void {
    intf.ssn_params.timeout = timeout;
}

fn sessionSetRetry(intf: *Intf, retry: c_int) callconv(.c) void {
    intf.ssn_params.retry = retry;
}

fn sessionCleanup(intf: *Intf) callconv(.c) void {
    const session = intf.session orelse return;
    c.free(session);
    intf.session = null;
}

fn ipmiCleanup(intf: *Intf) callconv(.c) void {
    c.ipmi_sdr_list_empty();
    sessionSetHostname(intf, null);
}

// ---------------------------------------------------------------------------
// The shared UDP socket
// ---------------------------------------------------------------------------

/// `struct sockaddr_in6`, per target.  See the `abi_layout.h` note: the C
/// `s6_addr` member is only reachable through a libc specific macro, so the
/// mirror comes from `std.posix` and is pinned against the C compiler's own
/// offsets below.
const SockaddrIn6 = std.posix.sockaddr.in6;

/// `IN6_IS_ADDR_MULTICAST()`.
fn in6IsAddrMulticast(addr: *const [16]u8) bool {
    return addr[0] == 0xff;
}

/// `IN6_IS_ADDR_LOOPBACK()`: `::1`.
fn in6IsAddrLoopback(addr: *const [16]u8) bool {
    return std.mem.allEqual(u8, addr[0..15], 0) and addr[15] == 1;
}

/// `IN6_IS_ADDR_LINKLOCAL()`: `fe80::/10`.
fn in6IsAddrLinklocal(addr: *const [16]u8) bool {
    return addr[0] == 0xfe and (addr[1] & 0xc0) == 0x80;
}

/// `ipmi_intf_socket_connect()`: resolve `ssn_params.hostname` and connect a
/// UDP socket to it, leaving the descriptor in `intf->fd`.
///
/// Returns 0 on success and -1 on failure.  Only compiled into the C when
/// `lan` or `lanplus` is enabled, and gated the same way here.
fn socketConnect(intf: ?*Intf) callconv(.c) c_int {
    const self = intf orelse return -1;

    // The C also declares `struct sockaddr_storage addr` and memsets it; it is
    // never read again, so it has no Zig counterpart.

    const params = &self.ssn_params;

    const hostname = params.hostname orelse {
        c.lprintf(log.Level.err, "No hostname specified!");
        return -1;
    };
    if (c.strlen(hostname) == 0) {
        c.lprintf(log.Level.err, "No hostname specified!");
        return -1;
    }

    var service: [c.NI_MAXSERV]u8 = undefined;
    _ = c.sprintf(&service, "%d", params.port);

    // Obtain address(es) matching host/port.
    var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = self.ai_family; // Allow IPv4 or IPv6.
    hints.ai_socktype = c.SOCK_DGRAM; // Datagram socket.
    hints.ai_flags = 0; // use AI_NUMERICSERV for no name resolution.
    hints.ai_protocol = c.IPPROTO_UDP;

    var rp0: [*c]c.struct_addrinfo = null;
    if (c.getaddrinfo(hostname, &service, &hints, &rp0) != 0) {
        c.lprintf(log.Level.err, "Address lookup for %s failed", hostname);
        return -1;
    }

    // getaddrinfo() returns a list of address structures.  Try each address
    // until we successfully connect(2).  If socket(2) (or connect(2)) fails, we
    // (close the socket and) try the next address.
    var rp = rp0;
    while (rp != null) : (rp = rp.*.ai_next) {
        // We are only interested in IPv4 and IPv6.
        if (rp.*.ai_family != c.AF_INET6 and rp.*.ai_family != c.AF_INET) {
            continue;
        }

        self.fd = c.socket(rp.*.ai_family, rp.*.ai_socktype, rp.*.ai_protocol);
        if (self.fd == -1) {
            continue;
        }

        if (rp.*.ai_family == c.AF_INET) {
            if (c.connect(self.fd, rp.*.ai_addr, rp.*.ai_addrlen) != -1) {
                hints.ai_family = rp.*.ai_family;
                break; // Success.
            }
        } else if (rp.*.ai_family == c.AF_INET6) {
            const addr6: *SockaddrIn6 = @ptrCast(@alignCast(rp.*.ai_addr));
            var hbuf: [c.NI_MAXHOST]u8 = undefined;
            var len: c.socklen_t = undefined;

            // The scope was specified on the command line e.g. with
            // -H FE80::219:99FF:FEA0:BD95%eth0
            if (addr6.scope_id != 0) {
                len = @sizeOf(SockaddrIn6);
                if (c.getnameinfo(
                    @ptrCast(addr6),
                    len,
                    &hbuf,
                    hbuf.len,
                    null,
                    0,
                    c.NI_NUMERICHOST,
                ) == 0) {
                    c.lprintf(
                        log.Level.debug,
                        "Trying address: %s scope=%d",
                        @as([*c]const u8, &hbuf),
                        @as(c_uint, addr6.scope_id),
                    );
                }
                if (c.connect(self.fd, rp.*.ai_addr, rp.*.ai_addrlen) != -1) {
                    hints.ai_family = rp.*.ai_family;
                    break; // Success.
                }
            } else {
                // No scope specified, try to get this from the list of
                // interfaces.
                var ifaddrs: [*c]c.struct_ifaddrs = null;

                if (c.getifaddrs(&ifaddrs) < 0) {
                    c.lprintf(
                        log.Level.err,
                        "Interface address lookup for %s failed",
                        hostname,
                    );
                    break;
                }

                var ifa = ifaddrs;
                while (ifa != null) : (ifa = ifa.*.ifa_next) {
                    const ifa_addr = ifa.*.ifa_addr orelse continue;

                    if (ifa_addr.*.sa_family != c.AF_INET6) continue;

                    const tmp6: *SockaddrIn6 = @ptrCast(@alignCast(ifa_addr));

                    // Skip unwanted addresses.
                    if (in6IsAddrMulticast(&tmp6.addr)) continue;
                    if (in6IsAddrLoopback(&tmp6.addr)) continue;

                    len = @sizeOf(SockaddrIn6);
                    if (c.getnameinfo(
                        @ptrCast(tmp6),
                        len,
                        &hbuf,
                        hbuf.len,
                        null,
                        0,
                        c.NI_NUMERICHOST,
                    ) == 0) {
                        c.lprintf(
                            log.Level.debug,
                            "Testing %s interface address: %s scope=%d",
                            @as([*c]const u8, if (ifa.*.ifa_name != null)
                                ifa.*.ifa_name
                            else
                                "???"),
                            @as([*c]const u8, &hbuf),
                            @as(c_uint, tmp6.scope_id),
                        );
                    }

                    if (tmp6.scope_id != 0) {
                        addr6.scope_id = tmp6.scope_id;
                    } else {
                        // No scope information in interface address
                        // information.  On some OS'es, getifaddrs() is
                        // returning out the 'kernel' representation of scoped
                        // addresses which stores the scope in the 3rd and 4th
                        // byte.
                        //
                        // Upstream reads that as `ntohs(s6_addr[1])`, i.e. it
                        // byte swaps a *single byte* and so shifts it left by
                        // eight on a little endian host.  Preserved verbatim.
                        if (in6IsAddrLinklocal(&tmp6.addr) and tmp6.addr[1] != 0) {
                            addr6.scope_id =
                                std.mem.bigToNative(u16, @as(u16, tmp6.addr[1]));
                        }
                    }

                    // OK, now try to connect with the scope id from this
                    // interface address.
                    if (addr6.scope_id != 0 or !in6IsAddrLinklocal(&tmp6.addr)) {
                        if (c.connect(self.fd, rp.*.ai_addr, rp.*.ai_addrlen) != -1) {
                            hints.ai_family = rp.*.ai_family;
                            c.lprintf(
                                log.Level.debug,
                                "Successful connected on %s interface with scope id %d",
                                @as([*c]const u8, ifa.*.ifa_name),
                                @as(c_uint, tmp6.scope_id),
                            );
                            break; // Success.
                        }
                    }
                }
                c.freeifaddrs(ifaddrs);
            }
        }
        // `hints.ai_family` doubles as the "connected" flag.  It starts out as
        // `intf->ai_family`, so with -4 or -6 on the command line this is
        // already non-zero and the loop stops after the first candidate whether
        // or not the connect() above succeeded.  Upstream behaviour, kept.
        if (hints.ai_family != c.AF_UNSPEC) {
            break;
        }
        _ = c.close(self.fd);
        self.fd = -1;
    }

    // No longer needed.
    c.freeaddrinfo(rp0);

    return if (self.fd != -1) 0 else -1;
}

// ---------------------------------------------------------------------------
// Payload size negotiation
// ---------------------------------------------------------------------------

/// `ipmi_intf_get_max_request_data_size()`.
///
/// The IPMB standard overall message length for non-bridging messages is 32
/// bytes including the slave address, which is where the default comes from;
/// `Send Message` bridging pays for its own wrapper out of that budget.
fn getMaxRequestDataSize(intf: *Intf) callconv(.c) u16 {
    const bridging_level = getBridgingLevel(intf);

    // uint16_t narrowed into an int16_t, as in the C.
    var size: i16 = @bitCast(intf.max_request_data_size);

    if (size == 0) {
        size = default_payload_size;
        // Add the Send Message request size when the message is forwarded.
        if (bridging_level != 0) size +%= 8;
    }

    if (bridging_level != 0) {
        // Subtract the send message request size.
        size -%= 8;

        // The forwarded request must still fit the default payload size.
        if (size > default_payload_size) size = default_payload_size;

        // Double bridging pays for the inner Send Message too.
        if (bridging_level == 2) size -%= 8;
    }

    if (size < 0) return 0;
    return @bitCast(size);
}

/// `ipmi_intf_get_max_response_data_size()`.
fn getMaxResponseDataSize(intf: *Intf) callconv(.c) u16 {
    const bridging_level = getBridgingLevel(intf);

    var size: i16 = @bitCast(intf.max_response_data_size);

    if (size == 0) {
        // Response length with the header and checksum byte subtracted.
        size = default_payload_size;
        // Add the Send Message header size when the message is forwarded.
        if (bridging_level != 0) size +%= 7;
    }

    if (bridging_level != 0) {
        // Some IPMI controllers like PICMG AMC carriers embed responses to the
        // forwarded messages into the Send Message response; subtract the
        // internal message header size so the response cannot be truncated.
        size -%= 8;

        if (size > default_payload_size) size = default_payload_size;

        if (bridging_level == 2) size -%= 8;
    }

    if (size < 0) return 0;
    return @bitCast(size);
}

/// `ipmi_intf_get_bridging_level()`: 0, 1 or 2 nested `Send Message` wrappers.
fn getBridgingLevel(intf: *const Intf) callconv(.c) u8 {
    if (intf.target_addr != 0 and intf.target_addr != intf.my_addr) {
        if (intf.transit_addr != 0 and
            (intf.transit_addr != intf.target_addr or
                intf.transit_channel != intf.target_channel))
        {
            return 2;
        }
        return 1;
    }
    return 0;
}

fn setMaxRequestDataSize(intf: *Intf, size: u16) callconv(.c) void {
    if (size < default_payload_size) {
        c.lprintf(
            log.Level.err,
            "Request size is too small (%d), leave default size",
            @as(c_int, size),
        );
        return;
    }

    if (intf.set_max_request_data_size) |hook| {
        hook(intf, size);
    } else {
        intf.max_request_data_size = size;
    }
}

fn setMaxResponseDataSize(intf: *Intf, size: u16) callconv(.c) void {
    if (size < default_payload_size - 1) {
        c.lprintf(
            log.Level.err,
            "Response size is too small (%d), leave default size",
            @as(c_int, size),
        );
        return;
    }

    if (intf.set_max_response_data_size) |hook| {
        hook(intf, size);
    } else {
        intf.max_response_data_size = size;
    }
}

// ---------------------------------------------------------------------------
// ABI parity
// ---------------------------------------------------------------------------

comptime {
    abi.assertOpaqueLayout(SockaddrIn6, .{
        .size = c.ABI_SIZEOF_sockaddr_in6,
        .alignment = c.ABI_ALIGNOF_sockaddr_in6,
        .fields = &.{
            .{ .name = "family", .offset = c.ABI_OFFSETOF_sockaddr_in6__sin6_family },
            .{ .name = "port", .offset = c.ABI_OFFSETOF_sockaddr_in6__sin6_port },
            .{ .name = "flowinfo", .offset = c.ABI_OFFSETOF_sockaddr_in6__sin6_flowinfo },
            .{ .name = "addr", .offset = c.ABI_OFFSETOF_sockaddr_in6__sin6_addr },
            .{ .name = "scope_id", .offset = c.ABI_OFFSETOF_sockaddr_in6__sin6_scope_id },
        },
    });
}

/// Called at comptime from `src/zig/exports.zig` when `intf` is selected.
///
/// The `assertCallSignature` calls live here rather than at file scope on
/// purpose: naming a C declaration emits a reference to it, and a file scope
/// reference is analysed even when the module is not selected.  See
/// doc/zig-migration/varargs-trampoline.md.
pub fn exportSymbols() void {
    @export(&ipmi_intf_table, .{ .name = "ipmi_intf_table", .linkage = .strong });

    abi.assertCallSignature(@TypeOf(ipmiIntfPrint), @TypeOf(c.ipmi_intf_print));
    @export(&ipmiIntfPrint, .{ .name = "ipmi_intf_print", .linkage = .strong });

    abi.assertCallSignature(@TypeOf(ipmiIntfLoad), @TypeOf(c.ipmi_intf_load));
    @export(&ipmiIntfLoad, .{ .name = "ipmi_intf_load", .linkage = .strong });

    abi.assertCallSignature(
        @TypeOf(sessionSetHostname),
        @TypeOf(c.ipmi_intf_session_set_hostname),
    );
    @export(&sessionSetHostname, .{
        .name = "ipmi_intf_session_set_hostname",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(sessionSetUsername),
        @TypeOf(c.ipmi_intf_session_set_username),
    );
    @export(&sessionSetUsername, .{
        .name = "ipmi_intf_session_set_username",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(sessionSetPassword),
        @TypeOf(c.ipmi_intf_session_set_password),
    );
    @export(&sessionSetPassword, .{
        .name = "ipmi_intf_session_set_password",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(sessionSetPrivlvl),
        @TypeOf(c.ipmi_intf_session_set_privlvl),
    );
    @export(&sessionSetPrivlvl, .{
        .name = "ipmi_intf_session_set_privlvl",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(sessionSetLookupbit),
        @TypeOf(c.ipmi_intf_session_set_lookupbit),
    );
    @export(&sessionSetLookupbit, .{
        .name = "ipmi_intf_session_set_lookupbit",
        .linkage = .strong,
    });

    // Only declared and defined when lanplus is in the build.
    if (@hasDecl(c, "IPMI_INTF_LANPLUS")) {
        abi.assertCallSignature(
            @TypeOf(sessionSetCipherSuiteId),
            @TypeOf(c.ipmi_intf_session_set_cipher_suite_id),
        );
        @export(&sessionSetCipherSuiteId, .{
            .name = "ipmi_intf_session_set_cipher_suite_id",
            .linkage = .strong,
        });
    }

    abi.assertCallSignature(
        @TypeOf(sessionSetSolEscapeChar),
        @TypeOf(c.ipmi_intf_session_set_sol_escape_char),
    );
    @export(&sessionSetSolEscapeChar, .{
        .name = "ipmi_intf_session_set_sol_escape_char",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(sessionSetKgkey),
        @TypeOf(c.ipmi_intf_session_set_kgkey),
    );
    @export(&sessionSetKgkey, .{
        .name = "ipmi_intf_session_set_kgkey",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(sessionSetPort),
        @TypeOf(c.ipmi_intf_session_set_port),
    );
    @export(&sessionSetPort, .{
        .name = "ipmi_intf_session_set_port",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(sessionSetAuthtype),
        @TypeOf(c.ipmi_intf_session_set_authtype),
    );
    @export(&sessionSetAuthtype, .{
        .name = "ipmi_intf_session_set_authtype",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(sessionSetTimeout),
        @TypeOf(c.ipmi_intf_session_set_timeout),
    );
    @export(&sessionSetTimeout, .{
        .name = "ipmi_intf_session_set_timeout",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(sessionSetRetry),
        @TypeOf(c.ipmi_intf_session_set_retry),
    );
    @export(&sessionSetRetry, .{
        .name = "ipmi_intf_session_set_retry",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(sessionCleanup),
        @TypeOf(c.ipmi_intf_session_cleanup),
    );
    @export(&sessionCleanup, .{
        .name = "ipmi_intf_session_cleanup",
        .linkage = .strong,
    });

    abi.assertCallSignature(@TypeOf(ipmiCleanup), @TypeOf(c.ipmi_cleanup));
    @export(&ipmiCleanup, .{ .name = "ipmi_cleanup", .linkage = .strong });

    // `#if defined(IPMI_INTF_LAN) || defined(IPMI_INTF_LANPLUS)`.
    if (@hasDecl(c, "IPMI_INTF_LAN") or @hasDecl(c, "IPMI_INTF_LANPLUS")) {
        abi.assertCallSignature(
            @TypeOf(socketConnect),
            @TypeOf(c.ipmi_intf_socket_connect),
        );
        @export(&socketConnect, .{
            .name = "ipmi_intf_socket_connect",
            .linkage = .strong,
        });
    }

    abi.assertCallSignature(
        @TypeOf(getMaxRequestDataSize),
        @TypeOf(c.ipmi_intf_get_max_request_data_size),
    );
    @export(&getMaxRequestDataSize, .{
        .name = "ipmi_intf_get_max_request_data_size",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(getMaxResponseDataSize),
        @TypeOf(c.ipmi_intf_get_max_response_data_size),
    );
    @export(&getMaxResponseDataSize, .{
        .name = "ipmi_intf_get_max_response_data_size",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(getBridgingLevel),
        @TypeOf(c.ipmi_intf_get_bridging_level),
    );
    @export(&getBridgingLevel, .{
        .name = "ipmi_intf_get_bridging_level",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(setMaxRequestDataSize),
        @TypeOf(c.ipmi_intf_set_max_request_data_size),
    );
    @export(&setMaxRequestDataSize, .{
        .name = "ipmi_intf_set_max_request_data_size",
        .linkage = .strong,
    });

    abi.assertCallSignature(
        @TypeOf(setMaxResponseDataSize),
        @TypeOf(c.ipmi_intf_set_max_response_data_size),
    );
    @export(&setMaxResponseDataSize, .{
        .name = "ipmi_intf_set_max_response_data_size",
        .linkage = .strong,
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the registry is null terminated and holds every enabled interface" {
    // The *contents* of `ipmi_intf_table` cannot be inspected here: it is built
    // from the C plugin globals and this test binary links no C objects.  The
    // exact list, in order, is asserted by the `-h` check in `build.zig`, which
    // compares the rendered interface list against the enabled plugin set.
    // What is checkable here is the shape.
    var enabled: usize = 0;
    inline for (registered) |entry| {
        if (@hasDecl(c, entry.macro)) enabled += 1;
    }
    try std.testing.expectEqual(enabled + 1, table_len);
    try std.testing.expect(enabled > 0);
}

/// Builds a table of `Intf` values with the given names for the lookup tests.
fn fakeTable(
    comptime names: []const []const u8,
    storage: *[names.len]Intf,
    table: *[names.len + 1]?*Intf,
) []const ?*Intf {
    for (names, 0..) |name, i| {
        storage[i] = std.mem.zeroes(Intf);
        @memcpy(storage[i].name[0..name.len], name);
        table[i] = &storage[i];
    }
    table[names.len] = null;
    return table;
}

test "the default interface is the one DEFAULT_INTF names" {
    // The two decoys must not themselves be `DEFAULT_INTF`, and the default
    // must not be first, or the lookup and the fallback would be
    // indistinguishable.
    const names = &[_][]const u8{ "decoy-one", c.DEFAULT_INTF, "decoy-two" };
    var storage: [names.len]Intf = undefined;
    var slots: [names.len + 1]?*Intf = undefined;
    const table = fakeTable(names, &storage, &slots);

    try std.testing.expectEqual(table[1], defaultInterface(table));
}

test "an absent default falls back to the first entry" {
    // Unreachable through the build system, which refuses a default that is
    // not enabled, but the C keeps the fallback and so does the port.
    const names = &[_][]const u8{ "first-one", "second-one" };
    var storage: [names.len]Intf = undefined;
    var slots: [names.len + 1]?*Intf = undefined;
    const table = fakeTable(names, &storage, &slots);

    try std.testing.expectEqual(table[0], defaultInterface(table));
}

test "lookup stops at the null terminator" {
    const names = &[_][]const u8{ "alpha", "beta" };
    var storage: [names.len]Intf = undefined;
    // One extra slot holding a live pointer *past* the terminator: the scan
    // must not reach it.
    var slots: [names.len + 2]?*Intf = undefined;
    for (names, 0..) |name, i| {
        storage[i] = std.mem.zeroes(Intf);
        @memcpy(storage[i].name[0..name.len], name);
        slots[i] = &storage[i];
    }
    slots[names.len] = null;
    slots[names.len + 1] = &storage[0];

    try std.testing.expectEqual(slots[0], findInterface(&slots, "alpha"));
    try std.testing.expectEqual(slots[1], findInterface(&slots, "beta"));
    try std.testing.expectEqual(@as(?*Intf, null), findInterface(&slots, "gamma"));
    // A prefix of a registered name is not a match: the C uses strcmp, not
    // strncmp, so `lan` must not select `lanplus` and vice versa.
    try std.testing.expectEqual(@as(?*Intf, null), findInterface(&slots, "alph"));
    try std.testing.expectEqual(@as(?*Intf, null), findInterface(&slots, "alphabet"));
    try std.testing.expectEqual(@as(?*Intf, null), findInterface(&slots, ""));
}

test "the -h filter keeps only the supported names" {
    const names = &[_][]const u8{ "alpha", "beta", "gamma" };
    var storage: [names.len]Intf = undefined;
    var slots: [names.len + 1]?*Intf = undefined;
    const table = fakeTable(names, &storage, &slots);

    const list = [_]IntfSupport{
        .{ .name = "alpha", .supported = 1 },
        .{ .name = "beta", .supported = 0 },
        .{ .name = null, .supported = 0 },
    };

    try std.testing.expect(isSupported(&list, table[0].?));
    try std.testing.expect(!isSupported(&list, table[1].?));
    // Absent from the list entirely.
    try std.testing.expect(!isSupported(&list, table[2].?));
}

test "IPv6 address classification matches the glibc macros" {
    const multicast: [16]u8 = .{0xff} ++ .{0} ** 15;
    const loopback: [16]u8 = .{0} ** 15 ++ .{1};
    const linklocal: [16]u8 = .{ 0xfe, 0x80 } ++ .{0} ** 14;
    // fea0::/10 is still link local.  It is here to pin the mask: `& 0xc0` and
    // `& 0xe0` agree on fe80:: and only disagree once the third bit is set.
    const linklocal_hi: [16]u8 = .{ 0xfe, 0xa0 } ++ .{0} ** 14;
    // fec0::/10 is site local: the first byte matches, the second does not.
    const sitelocal: [16]u8 = .{ 0xfe, 0xc0 } ++ .{0} ** 14;
    const global: [16]u8 = .{ 0x20, 0x01, 0x0d, 0xb8 } ++ .{0} ** 12;

    try std.testing.expect(in6IsAddrMulticast(&multicast));
    try std.testing.expect(!in6IsAddrMulticast(&global));

    try std.testing.expect(in6IsAddrLoopback(&loopback));
    try std.testing.expect(!in6IsAddrLoopback(&global));
    // All sixteen bytes matter: `::` is not the loopback address.
    try std.testing.expect(!in6IsAddrLoopback(&(.{0} ** 16)));

    try std.testing.expect(in6IsAddrLinklocal(&linklocal));
    try std.testing.expect(in6IsAddrLinklocal(&linklocal_hi));
    try std.testing.expect(!in6IsAddrLinklocal(&sitelocal));
    try std.testing.expect(!in6IsAddrLinklocal(&global));
}

test "payload sizes follow the bridging level" {
    var intf: Intf = std.mem.zeroes(Intf);

    // No bridging: the interface default, or 25 when it declares none.
    try std.testing.expectEqual(@as(u16, 25), getMaxRequestDataSize(&intf));
    try std.testing.expectEqual(@as(u16, 25), getMaxResponseDataSize(&intf));

    intf.max_request_data_size = 200;
    intf.max_response_data_size = 190;
    try std.testing.expectEqual(@as(u16, 200), getMaxRequestDataSize(&intf));
    try std.testing.expectEqual(@as(u16, 190), getMaxResponseDataSize(&intf));

    // One level of bridging clamps back down to the IPMB budget.
    intf.my_addr = 0x20;
    intf.target_addr = 0x82;
    try std.testing.expectEqual(@as(u8, 1), getBridgingLevel(&intf));
    try std.testing.expectEqual(@as(u16, 25), getMaxRequestDataSize(&intf));
    try std.testing.expectEqual(@as(u16, 25), getMaxResponseDataSize(&intf));

    // Two levels cost another Send Message wrapper.
    intf.transit_addr = 0x84;
    try std.testing.expectEqual(@as(u8, 2), getBridgingLevel(&intf));
    try std.testing.expectEqual(@as(u16, 17), getMaxRequestDataSize(&intf));
    try std.testing.expectEqual(@as(u16, 17), getMaxResponseDataSize(&intf));

    // A transit address equal to the target on the same channel is not a
    // second hop.
    intf.transit_addr = intf.target_addr;
    intf.transit_channel = intf.target_channel;
    try std.testing.expectEqual(@as(u8, 1), getBridgingLevel(&intf));

    // ... but the same address on a different channel is.
    intf.transit_channel = 7;
    intf.target_channel = 3;
    try std.testing.expectEqual(@as(u8, 2), getBridgingLevel(&intf));
}

test "an interface with no declared size gets the bridging allowance" {
    var intf: Intf = std.mem.zeroes(Intf);
    intf.my_addr = 0x20;
    intf.target_addr = 0x82;

    // 25 + 8 - 8 for the request, 25 + 7 - 8 for the response: the response
    // allowance is one byte short of the request one on purpose, because the
    // Send Message response header is one byte shorter.
    try std.testing.expectEqual(@as(u16, 25), getMaxRequestDataSize(&intf));
    try std.testing.expectEqual(@as(u16, 24), getMaxResponseDataSize(&intf));
}

test "BUG: a narrow uint16 payload size wraps into a negative int16" {
    var intf: Intf = std.mem.zeroes(Intf);

    // The C stores `intf->max_request_data_size` (uint16_t) in an int16_t, so
    // any interface declaring more than 32767 bytes reports zero instead.
    intf.max_request_data_size = 0x8000;
    intf.max_response_data_size = 0xffff;
    try std.testing.expectEqual(@as(u16, 0), getMaxRequestDataSize(&intf));
    try std.testing.expectEqual(@as(u16, 0), getMaxResponseDataSize(&intf));
}

test "session parameter setters truncate the way the C does" {
    var intf: Intf = std.mem.zeroes(Intf);

    // The username field is 17 bytes but only 16 are ever copied.
    sessionSetUsername(&intf, @constCast("0123456789abcdefTRUNCATED"));
    try std.testing.expectEqualStrings(
        "0123456789abcdef",
        std.mem.sliceTo(&intf.ssn_params.username, 0),
    );

    // The authcode buffer is 21 bytes but only 20 are ever copied, and only 20
    // are ever cleared.
    sessionSetPassword(&intf, @constCast("0123456789abcdefghijTRUNCATED"));
    try std.testing.expectEqual(@as(c_int, 1), intf.ssn_params.password);
    try std.testing.expectEqualStrings(
        "0123456789abcdefghij",
        std.mem.sliceTo(&intf.ssn_params.authcode_set, 0),
    );

    sessionSetPassword(&intf, null);
    try std.testing.expectEqual(@as(c_int, 0), intf.ssn_params.password);
    try std.testing.expectEqual(@as(u8, 0), intf.ssn_params.authcode_set[0]);

    // Authtype NONE clears the password again.
    sessionSetPassword(&intf, @constCast("secret"));
    sessionSetAuthtype(&intf, c.IPMI_SESSION_AUTHTYPE_NONE);
    try std.testing.expectEqual(@as(c_int, 0), intf.ssn_params.password);
    try std.testing.expectEqual(@as(u8, 0), intf.ssn_params.authcode_set[0]);
    try std.testing.expectEqual(
        @as(u8, c.IPMI_SESSION_AUTHTYPE_NONE),
        intf.ssn_params.authtype_set,
    );

    // Any other authtype leaves it alone.
    sessionSetPassword(&intf, @constCast("secret"));
    sessionSetAuthtype(&intf, c.IPMI_SESSION_AUTHTYPE_MD5);
    try std.testing.expectEqual(@as(c_int, 1), intf.ssn_params.password);
    try std.testing.expectEqualStrings(
        "secret",
        std.mem.sliceTo(&intf.ssn_params.authcode_set, 0),
    );

    // The full 21 byte Kg buffer is copied, terminator included.
    const kg: [intf_mod.kg_buffer_size]u8 = .{
        0x51, 0x62, 0x73, 0x84, 0x95, 0xa6, 0xb7, 0xc8, 0xd9, 0xea, 0xfb,
        0x1c, 0x2d, 0x3e, 0x4f, 0x50, 0x61, 0x72, 0x83, 0x94, 0xa5,
    };
    sessionSetKgkey(&intf, &kg);
    try std.testing.expectEqualSlices(u8, &kg, &intf.ssn_params.kg);
}

test "hostname round trips through the C allocator" {
    var intf: Intf = std.mem.zeroes(Intf);

    sessionSetHostname(&intf, @constCast("bmc.example.test"));
    try std.testing.expectEqualStrings(
        "bmc.example.test",
        std.mem.sliceTo(intf.ssn_params.hostname.?, 0),
    );

    // Setting it again frees the previous copy rather than leaking it.
    sessionSetHostname(&intf, @constCast("other.example.test"));
    try std.testing.expectEqualStrings(
        "other.example.test",
        std.mem.sliceTo(intf.ssn_params.hostname.?, 0),
    );

    sessionSetHostname(&intf, null);
    try std.testing.expectEqual(@as(?[*:0]u8, null), intf.ssn_params.hostname);
}
