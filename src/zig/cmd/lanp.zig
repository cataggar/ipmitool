//! IPv4 LAN configuration (`lib/ipmi_lanp.c`). The IPv6 `lan6` command is a
//! separate translation unit; this module exports only `ipmi_lanp_main` and
//! `find_lan_channel`, so either module can be selected independently.
const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;

const Param = enum(u8) {
    progress = 0,
    auth = 1,
    auth_enable = 2,
    ip = 3,
    source = 4,
    mac = 5,
    mask = 6,
    header = 7,
    primary_port = 8,
    secondary_port = 9,
    arp = 10,
    grat = 11,
    gateway = 12,
    gateway_mac = 13,
    backup = 14,
    backup_mac = 15,
    snmp = 16,
    destinations = 17,
    dest_type = 18,
    dest_addr = 19,
    vlan = 20,
    priority = 21,
    cipher_count = 22,
    ciphers = 23,
    cipher_priv = 24,
    threshold = 26,
};
const names = [_][*:0]const u8{
    "Set in Progress",       "Auth Type Support",        "Auth Type Enable",
    "IP Address",            "IP Address Source",        "MAC Address",
    "Subnet Mask",           "IP Header",                "Primary RMCP Port",
    "Secondary RMCP Port",   "BMC ARP Control",          "Gratuitous ARP Intrvl",
    "Default Gateway IP",    "Default Gateway MAC",      "Backup Gateway IP",
    "Backup Gateway MAC",    "SNMP Community String",    "Number of Destinations",
    "Destination Type",      "Destination Addresses",    "802.1q VLAN ID",
    "802.1q VLAN Priority",  "RMCP+ Cipher Suite Count", "RMCP+ Cipher Suites",
    "Cipher Suite Priv Max", "",                         "Bad Password Threshold",
};
const max_channel: u8 = 14;
const transport: u6 = @intCast(c.IPMI_NETFN_TRANSPORT);
const Err = error{ CommandFailed, ShortResponse, InvalidParameter };
const Value = struct { bytes: ?[]const u8 };

fn pName(p: Param) [*:0]const u8 {
    return names[@intFromEnum(p)];
}
fn ci(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}
fn eql(s: [*:0]const u8, lit: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(s), lit);
}
fn eqi(s: [*:0]const u8, lit: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.span(s), lit);
}
fn arg(argv: [*c][*c]u8, i: usize) [*:0]const u8 {
    return @ptrCast(argv[i]);
}
fn send(intf: *Intf, cmd: u8, data: []const u8) ?*ipmi.Response {
    const sendrecv = intf.sendrecv orelse return null;
    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = transport;
    req.msg.cmd = cmd;
    req.msg.data = @ptrCast(@constCast(data.ptr));
    req.msg.data_len = @intCast(data.len);
    return sendrecv(intf, &req);
}
fn ccode(code: u8, is_set: bool) [*c]const u8 {
    return c.specific_val2str(code, if (is_set) &set_codes else &get_codes, c.completion_code_vals);
}
const set_codes = [_]c.struct_valstr{
    .{ .val = 0x80, .str = "Unsupported parameter" },
    .{ .val = 0x81, .str = "Attempt to set 'in progress' while not in 'complete' state" },
    .{ .val = 0x82, .str = "Parameter is read-only" },
    .{ .val = 0x83, .str = "Parameter is wrote-only" },
    .{ .val = 0, .str = null },
};
const get_codes = [_]c.struct_valstr{
    .{ .val = 0x80, .str = "Unsupported parameter" },
    .{ .val = 0, .str = null },
};

fn get(intf: *Intf, ch: u8, p: Param, selector: u8) Err!Value {
    const payload = [_]u8{ ch, @intFromEnum(p), selector, 0 };
    const rsp = send(intf, c.IPMI_LAN_GET_CONFIG, &payload) orelse {
        log.print(log.Level.info, "Get LAN Parameter '%s' command failed", .{pName(p)});
        return error.CommandFailed;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.info, "Get LAN Parameter '%s' command failed: %s", .{ pName(p), ccode(rsp.ccode, false) });
        if (rsp.ccode == 0x80 or rsp.ccode == 0xc9 or rsp.ccode == 0xcc)
            return .{ .bytes = null };
        return error.CommandFailed;
    }
    if (rsp.data_len <= 0) return .{ .bytes = null };
    if (@as(usize, @intCast(rsp.data_len)) > rsp.data.len) return error.ShortResponse;
    return .{ .bytes = rsp.data[1..@intCast(rsp.data_len)] };
}
fn required(v: Value, len: usize) Err![]const u8 {
    const bytes = v.bytes orelse return error.ShortResponse;
    if (bytes.len < len) return error.ShortResponse;
    return bytes;
}
fn rawSet(intf: *Intf, ch: u8, p: Param, value: []const u8, wait: bool) Err!void {
    if (value.len > 30) return error.InvalidParameter;
    var bytes: [32]u8 = undefined;
    bytes[0] = ch;
    bytes[1] = @intFromEnum(p);
    @memcpy(bytes[2..][0..value.len], value);
    const rsp = send(intf, c.IPMI_LAN_SET_CONFIG, bytes[0 .. value.len + 2]) orelse {
        log.print(log.Level.err, "Set LAN Parameter failed", .{});
        return error.CommandFailed;
    };
    if (!wait) {
        if (rsp.ccode != 0) return error.CommandFailed;
        return;
    }
    if (rsp.ccode != 0 and rsp.ccode != 0xff) {
        log.print(log.Level.debug, "Warning: Set LAN Parameter failed: %s", .{ccode(rsp.ccode, true)});
        if (rsp.ccode != 0xcc) return error.CommandFailed;
        log.print(log.Level.debug, "Retrying...", .{});
        var tries: usize = 10;
        while (tries > 0) : (tries -= 1) {
            _ = c.sleep(c.IPMI_LANP_TIMEOUT);
            const next = send(intf, c.IPMI_LAN_SET_CONFIG, bytes[0 .. value.len + 2]) orelse continue;
            if (next.ccode == 0) break;
        } else return error.CommandFailed;
    }
    log.print(log.Level.debug, "Waiting for Set LAN Parameter to complete...", .{});
    if (c.verbose > 1) c.printbuf(value.ptr, @intCast(value.len), "SET DATA");
    var tries: usize = 0;
    while (true) : (tries += 1) {
        const check = get(intf, ch, p, 0) catch Value{ .bytes = null };
        if (c.verbose > 1) {
            if (check.bytes) |b|
                c.printbuf(b.ptr, @intCast(b.len), "READ DATA")
            else
                c.printbuf(null, 0, "READ DATA");
        }
        if (check.bytes) |actual| {
            if (std.mem.eql(u8, actual, value)) return;
        }
        if (tries == 10) {
            if (check.bytes) |actual| {
                if (actual.len != value.len)
                    log.print(log.Level.warning, "Mismatched data lengths: %d != %d", .{ @as(c_int, @intCast(actual.len)), @as(c_int, @intCast(value.len)) })
                else
                    log.print(log.Level.warning, "LAN Parameter Data does not match!  Write may have failed.", .{});
            }
            return error.CommandFailed;
        }
        _ = c.sleep(c.IPMI_LANP_TIMEOUT);
    }
}
fn lock(intf: *Intf, ch: u8) void {
    var retry: usize = 0;
    while (retry <= 3) : (retry += 1) {
        const state = get(intf, ch, .progress, 0) catch break;
        const bytes = required(state, 1) catch break;
        if (bytes[0] & 3 == 1) break;
        if (retry == 3) break;
        rawSet(intf, ch, .progress, &.{1}, false) catch {};
    }
}
fn set(intf: *Intf, ch: u8, p: Param, value: []const u8, wait: bool) c_int {
    lock(intf, ch);
    const result = rawSet(intf, ch, p, value, wait);
    rawSet(intf, ch, .progress, &.{2}, false) catch {
        log.print(log.Level.debug, "LAN Parameter Commit not supported", .{});
    };
    rawSet(intf, ch, .progress, &.{0}, false) catch {};
    result catch return -1;
    return 0;
}
fn lanChannel(intf: *Intf, ch: u8) bool {
    if (ch < 1 or ch > max_channel) return false;
    const medium = c.ipmi_get_channel_medium(ci(intf), ch);
    return medium == c.IPMI_CHANNEL_MEDIUM_LAN or medium == c.IPMI_CHANNEL_MEDIUM_LAN_OTHER;
}
fn findChannel(intf: *Intf, start: u8) callconv(.c) u8 {
    var ch = start;
    while (ch < max_channel) : (ch += 1) {
        if (lanChannel(intf, ch)) return ch;
    }
    return 0;
}
fn parseChannel(s: [*:0]const u8) ?u8 {
    var ch: u8 = 0;
    if (c.str2uchar(s, &ch) != 0) return null;
    return ch;
}
fn printIP(name: [*:0]const u8, b: []const u8) void {
    _ = c.printf("%-24s: %d.%d.%d.%d\n", name, @as(c_int, b[0]), @as(c_int, b[1]), @as(c_int, b[2]), @as(c_int, b[3]));
}
fn printMAC(name: [*:0]const u8, b: []const u8) void {
    _ = c.printf("%-24s: %s\n", name, c.mac2str(@ptrCast(b.ptr)));
}
fn fetchPrint(intf: *Intf, ch: u8, p: Param) Err!?[]const u8 {
    const value = try get(intf, ch, p, 0);
    return value.bytes;
}
fn printAuth(bits: u8) void {
    _ = c.printf("%s%s%s%s%s\n", if (bits & 1 != 0) @as([*:0]const u8, "NONE ") else "", if (bits & 2 != 0) @as([*:0]const u8, "MD2 ") else "", if (bits & 4 != 0) @as([*:0]const u8, "MD5 ") else "", if (bits & 16 != 0) @as([*:0]const u8, "PASSWORD ") else "", if (bits & 32 != 0) @as([*:0]const u8, "OEM ") else "");
}
fn privChar(value: u8) u8 {
    return switch (value) {
        1 => 'c',
        2 => 'u',
        3 => 'o',
        4 => 'a',
        5 => 'O',
        else => 'X',
    };
}
fn printLan(intf: *Intf, ch: u8) c_int {
    if (ch < 1 or ch > max_channel) {
        log.print(log.Level.err, "Invalid Channel %d", .{@as(c_int, ch)});
        return -1;
    }
    if (!lanChannel(intf, ch)) {
        log.print(log.Level.err, "Channel %d is not a LAN channel", .{@as(c_int, ch)});
        return -1;
    }
    const progress = fetchPrint(intf, ch, .progress) catch return -1;
    if (progress) |v| if (v.len >= 1) {
        _ = c.printf("%-24s: %s\n", pName(.progress), switch (v[0] & 3) {
            0 => @as([*:0]const u8, "Set Complete"),
            1 => "Set In Progress",
            2 => "Commit Write",
            else => "Reserved",
        });
    };
    const auth = fetchPrint(intf, ch, .auth) catch return -1;
    if (auth) |v| if (v.len >= 1) {
        _ = c.printf("%-24s: ", pName(.auth));
        printAuth(v[0]);
    };
    const enabled = fetchPrint(intf, ch, .auth_enable) catch return -1;
    if (enabled) |v| if (v.len >= 5) {
        const levels = [_][*:0]const u8{ "Callback", "User    ", "Operator", "Admin   ", "OEM     " };
        for (levels, 0..) |level, i| {
            _ = c.printf("%-24s: %s : ", if (i == 0) pName(.auth_enable) else @as([*:0]const u8, ""), level);
            printAuth(v[i]);
        }
    };
    const src = fetchPrint(intf, ch, .source) catch return -1;
    if (src) |v| if (v.len >= 1) {
        _ = c.printf("%-24s: %s\n", pName(.source), switch (v[0] & 15) {
            0 => @as([*:0]const u8, "Unspecified"),
            1 => "Static Address",
            2 => "DHCP Address",
            3 => "BIOS Assigned Address",
            else => "Other",
        });
    };
    inline for (.{ .ip, .mask, .mac, .snmp, .header, .arp, .grat, .gateway, .gateway_mac, .backup, .backup_mac }) |p| {
        const data = fetchPrint(intf, ch, p) catch return -1;
        if (data) |v| switch (p) {
            .ip, .mask, .gateway, .backup => {
                if (v.len >= 4) printIP(pName(p), v);
            },
            .mac, .gateway_mac, .backup_mac => {
                if (v.len >= 6) printMAC(pName(p), v);
            },
            .snmp => {
                if (std.mem.indexOfScalar(u8, v, 0)) |end| {
                    _ = c.printf("%-24s: %.*s\n", pName(p), @as(c_int, @intCast(end)), v.ptr);
                } else {
                    _ = c.printf("%-24s: %.*s\n", pName(p), @as(c_int, @intCast(v.len)), v.ptr);
                }
            },
            .header => {
                if (v.len >= 3)
                    _ = c.printf("%-24s: TTL=0x%02x Flags=0x%02x Precedence=0x%02x TOS=0x%02x\n", pName(p), @as(c_int, v[0]), @as(c_int, v[1] & 0xe0), @as(c_int, v[2] & 0xe0), @as(c_int, v[2] & 0x1e));
            },
            .arp => {
                if (v.len >= 1)
                    _ = c.printf("%-24s: ARP Responses %sabled, Gratuitous ARP %sabled\n", pName(p), if (v[0] & 2 != 0) @as([*:0]const u8, "En") else "Dis", if (v[0] & 1 != 0) @as([*:0]const u8, "En") else "Dis");
            },
            .grat => {
                if (v.len >= 1)
                    _ = c.printf("%-24s: %.1f seconds\n", pName(p), @as(f64, @floatFromInt((@as(u16, v[0]) + 1) / 2)));
            },
            else => unreachable,
        };
    }
    const vlan = fetchPrint(intf, ch, .vlan) catch null;
    if (vlan) |v| if (v.len >= 2) {
        if (v[1] & 0x80 != 0)
            _ = c.printf("%-24s: %d\n", pName(.vlan), @as(c_int, (@as(u16, v[1] & 15) << 8) | v[0]))
        else
            _ = c.printf("%-24s: Disabled\n", pName(.vlan));
    };
    const priority = fetchPrint(intf, ch, .priority) catch null;
    if (priority) |v| {
        if (v.len >= 1) _ = c.printf("%-24s: %d\n", pName(.priority), @as(c_int, v[0] & 7));
    }
    const count = fetchPrint(intf, ch, .cipher_count) catch return -1;
    if (count) |v| if (v.len >= 1) {
        const suite_count = v[0];
        const suites = fetchPrint(intf, ch, .ciphers) catch return -1;
        _ = c.printf("%-24s: ", pName(.ciphers));
        if (suites) |b| {
            if (b.len <= 17 and b.len > 0) {
                const n = @min(@as(usize, suite_count), 16);
                for (0..@min(n, b.len - 1)) |i|
                    _ = c.printf("%s%d", if (i > 0) @as([*:0]const u8, ",") else "", @as(c_int, b[i + 1]));
                _ = c.printf("\n");
            } else _ = c.printf("None\n");
        } else _ = c.printf("None\n");
    };
    const levels = fetchPrint(intf, ch, .cipher_priv) catch return -1;
    if (levels) |v| {
        if (v.len == 9) {
            var text: [16]u8 = undefined;
            for (0..15) |i| text[i] = privChar(if (i & 1 == 0) v[1 + i / 2] & 15 else v[1 + i / 2] >> 4);
            text[15] = 0;
            _ = c.printf("%-24s: %s\n", pName(.cipher_priv), &text);
            for ([_][*:0]const u8{
                "    X=Cipher Suite Unused", "    c=CALLBACK", "    u=USER",
                "    o=OPERATOR",            "    a=ADMIN",    "    O=OEM",
            }) |legend| _ = c.printf("%-24s: %s\n", @as([*:0]const u8, ""), legend);
        } else _ = c.printf("%-24s: Not Available\n", pName(.cipher_priv));
    } else _ = c.printf("%-24s: Not Available\n", pName(.cipher_priv));
    const threshold = fetchPrint(intf, ch, .threshold) catch return -1;
    if (threshold) |v| {
        if (v.len == 6) {
            _ = c.printf("%-24s: %d\n", pName(.threshold), @as(c_int, v[1]));
            _ = c.printf("%-24s: %s\n", @as([*:0]const u8, "Invalid password disable"), if (v[0] & 1 != 0) @as([*:0]const u8, "yes") else "no");
            _ = c.printf("%-24s: %d\n", @as([*:0]const u8, "Attempt Count Reset Int."), @as(c_int, v[2]) * 10 + @as(c_int, v[3]) * 2560);
            _ = c.printf("%-24s: %d\n", @as([*:0]const u8, "User Lockout Interval"), @as(c_int, v[4]) * 10 + @as(c_int, v[5]) * 2560);
        } else _ = c.printf("%-24s: Not Available\n", pName(.threshold));
    } else _ = c.printf("%-24s: Not Available\n", pName(.threshold));
    return 0;
}

fn usage(comptime kind: enum { lan, set, access, arp, auth, bakgw, cipher, defgw, ipsrc, snmp, vlan, bad_pass, alert_print, alert_set }) void {
    const text = switch (kind) {
        .lan => "LAN Commands:\n" ++
            "\t\t   print [<channel number>]\n" ++
            "\t\t   set <channel number> <command> <parameter>\n" ++
            "\t\t   alert print <channel number> <alert destination>\n" ++
            "\t\t   alert set <channel number> <alert destination> <command> <parameter>\n" ++
            "\t\t   stats get [<channel number>]\n" ++
            "\t\t   stats clear [<channel number>]",
        .set => "\nusage: lan set <channel> <command> <parameter>\n\n" ++
            "LAN set command/parameter options:\n" ++
            "  ipaddr <x.x.x.x>               Set channel IP address\n" ++
            "  netmask <x.x.x.x>              Set channel IP netmask\n" ++
            "  macaddr <x:x:x:x:x:x>          Set channel MAC address\n" ++
            "  defgw ipaddr <x.x.x.x>         Set default gateway IP address\n" ++
            "  defgw macaddr <x:x:x:x:x:x>    Set default gateway MAC address\n" ++
            "  bakgw ipaddr <x.x.x.x>         Set backup gateway IP address\n" ++
            "  bakgw macaddr <x:x:x:x:x:x>    Set backup gateway MAC address\n" ++
            "  password <password>            Set session password for this channel\n" ++
            "  snmp <community string>        Set SNMP public community string\n" ++
            "  user                           Enable default user for this channel\n" ++
            "  access <on|off>                Enable or disable access to this channel\n" ++
            "  alert <on|off>                 Enable or disable PEF alerting for this channel\n" ++
            "  arp respond <on|off>           Enable or disable BMC ARP responding\n" ++
            "  arp generate <on|off>          Enable or disable BMC gratuitous ARP generation\n" ++
            "  arp interval <seconds>         Set gratuitous ARP generation interval\n" ++
            "  vlan id <off|<id>>             Disable or enable VLAN and set ID (1-4094)\n" ++
            "  vlan priority <priority>       Set vlan priority (0-7)\n" ++
            "  auth <level> <type,..>         Set channel authentication types\n" ++
            "    level  = CALLBACK, USER, OPERATOR, ADMIN\n" ++
            "    type   = NONE, MD2, MD5, PASSWORD, OEM\n" ++
            "  ipsrc <source>                 Set IP Address source\n" ++
            "    none   = unspecified source\n" ++
            "    static = address manually configured to be static\n" ++
            "    dhcp   = address obtained by BMC running DHCP\n" ++
            "    bios   = address loaded by BIOS or system software\n" ++
            "  cipher_privs XXXXXXXXXXXXXXX   Set RMCP+ cipher suite privilege levels\n" ++
            "    X = Cipher Suite Unused\n" ++
            "    c = CALLBACK\n" ++
            "    u = USER\n" ++
            "    o = OPERATOR\n" ++
            "    a = ADMIN\n" ++
            "    O = OEM\n\n" ++
            "  bad_pass_thresh <thresh_num> <1|0> <reset_interval> <lockout_interval>\n" ++
            "                                Set bad password threshold",
        .access => "lan set access <on|off>",
        .arp => "lan set <channel> arp respond <on|off>\n" ++
            "lan set <channel> arp generate <on|off>\n" ++
            "lan set <channel> arp interval <seconds>\n\n" ++
            "example: lan set 7 arp gratuitous off",
        .auth => "lan set <channel> auth <level> <type,type,...>\n" ++
            "  level = CALLBACK, USER, OPERATOR, ADMIN\n" ++
            "  types = NONE, MD2, MD5, PASSWORD, OEM\n" ++
            "example: lan set 7 auth ADMIN PASSWORD,MD5",
        .bakgw => "LAN set backup gateway commands: ipaddr, macaddr",
        .cipher => "lan set <channel> cipher_privs XXXXXXXXXXXXXXX\n" ++
            "    X = Cipher Suite Unused\n    c = CALLBACK\n    u = USER\n" ++
            "    o = OPERATOR\n    a = ADMIN\n    O = OEM\n",
        .defgw => "LAN set default gateway Commands: ipaddr, macaddr",
        .ipsrc => "lan set <channel> ipsrc <source>\n" ++
            "  none   = unspecified\n  static = static address (manually configured)\n" ++
            "  dhcp   = address obtained by BMC running DHCP\n" ++
            "  bios   = address loaded by BIOS or system software",
        .snmp => "lan set <channel> snmp <community string>",
        .vlan => "lan set <channel> vlan id <id>\nlan set <channel> vlan id off\nlan set <channel> vlan priority <priority>",
        .bad_pass => "lan set <channel> bad_pass_thresh <thresh_num> <1|0> <reset_interval> <lockout_interval>\n" ++
            "        <thresh_num>         Bad Password Threshold number.\n" ++
            "        <1|0>                1 = generate a Session Audit sensor event.\n" ++
            "                             0 = do not generate an event.\n" ++
            "        <reset_interval>     Attempt Count Reset Interval. In tens of seconds.\n" ++
            "        <lockount_interval>  User Lockout Interval. In tens of seconds.",
        .alert_print => "\nusage: lan alert print [channel number] [alert destination]\n\n" ++
            "Default will print all alerts for the first found LAN channel",
        .alert_set => "\nusage: lan alert set <channel number> <alert destination> <command> <parameter>\n\n" ++
            "    Command/parameter options:\n\n" ++
            "    ipaddr <x.x.x.x>               Set alert IP address\n" ++
            "    macaddr <x:x:x:x:x:x>          Set alert MAC address\n" ++
            "    gateway <default|backup>       Set channel gateway to use for alerts\n" ++
            "    ack <on|off>                   Set Alert Acknowledge on or off\n" ++
            "    type <pet|oem1|oem2>           Set destination type as PET or OEM\n" ++
            "    time <seconds>                 Set ack timeout or unack retry interval\n" ++
            "    retry <number>                 Set number of alert retries\n",
    };
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| log.print(log.Level.notice, "%.*s", .{ @as(c_int, @intCast(line.len)), line.ptr });
}
fn parseIP(s: [*:0]const u8, out: *[4]u8) bool {
    var octets: [4]c_uint = undefined;
    if (c.sscanf(s, "%u.%u.%u.%u", &octets[0], &octets[1], &octets[2], &octets[3]) != 4 or
        octets[0] > 255 or octets[1] > 255 or octets[2] > 255 or octets[3] > 255)
    {
        log.print(log.Level.err, "Invalid IP address: %s", .{s});
        return false;
    }
    for (out, octets) |*slot, n| slot.* = @intCast(n);
    return true;
}
fn parseMac(s: [*:0]const u8, out: *[6]u8) bool {
    return c.str2mac(@constCast(s), @ptrCast(out)) == 0;
}
fn valU8(s: [*:0]const u8) ?u8 {
    var n: u8 = 0;
    if (c.str2uchar(s, &n) != 0) return null;
    return n;
}
fn valU16(s: [*:0]const u8) ?u16 {
    var n: u16 = 0;
    if (c.str2ushort(s, &n) != 0) return null;
    return n;
}
fn valInt(s: [*:0]const u8) ?c_int {
    var n: c_int = 0;
    if (c.str2int(s, &n) != 0) return null;
    return n;
}
fn printSetting(ch: u8, p: Param, b: []const u8) void {
    _ = ch;
    _ = c.printf("Setting LAN %s to ", pName(p));
    if (b.len == 4) {
        _ = c.printf("%d.%d.%d.%d\n", @as(c_int, b[0]), @as(c_int, b[1]), @as(c_int, b[2]), @as(c_int, b[3]));
    } else _ = c.printf("%s\n", c.mac2str(@ptrCast(b.ptr)));
}
fn channelAccess(intf: *Intf, ch: u8, enable: bool, alert: bool) c_int {
    var a = std.mem.zeroes(c.struct_channel_access_t);
    a.channel = ch;
    if (c.eval_ccode(c._ipmi_get_channel_access(ci(intf), &a, 0)) != 0) {
        log.print(log.Level.err, "Unable to Get Channel Access(non-volatile) for channel %d", .{@as(c_int, ch)});
        return -1;
    }
    if (alert) {
        a.alerting = if (enable) c.ALERTING_ENABLED else c.ALERTING_DISABLED;
        if (c.eval_ccode(c._ipmi_set_channel_access(ci(intf), a, 1, 0)) != 0) {
            log.print(log.Level.err, "Unable to Set Channel Access(non-volatile) for channel %d", .{@as(c_int, ch)});
            return -1;
        }
        if (c.eval_ccode(c._ipmi_set_channel_access(ci(intf), a, 2, 0)) != 0) {
            log.print(log.Level.err, "Unable to Set Channel Access(volatile) for channel %d", .{@as(c_int, ch)});
            return -1;
        }
        _ = c.printf("PEF alerts for channel %d %s.\n", @as(c_int, ch), if (enable) @as([*:0]const u8, "enabled") else "disabled");
    } else {
        a.access_mode = if (enable) 2 else 0;
        a.privilege_limit = 4;
        if (c.eval_ccode(c._ipmi_set_channel_access(ci(intf), a, 1, 1)) != 0) {
            log.print(log.Level.err, "Unable to Set Channel Access(non-volatile) for channel %d", .{@as(c_int, ch)});
            return -1;
        }
        a = std.mem.zeroes(c.struct_channel_access_t);
        a.channel = ch;
        if (c.eval_ccode(c._ipmi_get_channel_access(ci(intf), &a, 1)) != 0) {
            log.print(log.Level.err, "Unable to Get Channel Access(volatile) for channel %d", .{@as(c_int, ch)});
            return -1;
        }
        a.access_mode = if (enable) 2 else 0;
        a.privilege_limit = 4;
        if (c.eval_ccode(c._ipmi_set_channel_access(ci(intf), a, 2, 2)) != 0) {
            log.print(log.Level.err, "Unable to Set Channel Access(volatile) for channel %d", .{@as(c_int, ch)});
            return -1;
        }
        if (!enable) intf.abort = 1;
        _ = c.printf("Set Channel Access for channel %d was successful.\n", @as(c_int, ch));
    }
    return 0;
}
fn vlanSet(intf: *Intf, ch: u8, value: [*:0]const u8) c_int {
    var b: [2]u8 = undefined;
    if (eql(value, "off")) {
        log.print(log.Level.debug, "Get current VLAN ID from BMC.", .{});
        const current = get(intf, ch, .vlan, 0) catch Value{ .bytes = null };
        if (current.bytes) |v| {
            if (v.len >= 2) {
                const id = (@as(c_int, v[1] & 15) << 8) | v[0];
                if (id == 0) {
                    _ = c.printf("VLAN is already disabled for channel %d\n", @as(c_int, ch));
                    return 0;
                }
                if (id > 4094) {
                    log.print(log.Level.err, "Retrieved VLAN ID %i is out of range <1..4094>.", .{@as(c_int, id)});
                    return -1;
                }
                b = .{ v[0], v[1] & 15 };
            } else b = .{ 0, 0 };
        } else b = .{ 0, 0 };
    } else {
        const id = valInt(value) orelse {
            log.print(log.Level.err, "Given VLAN ID '%s' is invalid.", .{value});
            return -1;
        };
        if (id < 1 or id > 4094) {
            log.print(log.Level.notice, "VLAN ID must be between 1 and 4094.", .{});
            return -1;
        }
        b = .{ @truncate(@as(u32, @intCast(id))), @truncate((@as(u32, @intCast(id)) >> 8) | 0x80) };
    }
    return set(intf, ch, .vlan, &b, true);
}
fn authSet(intf: *Intf, ch: u8, level: [*:0]const u8, types: [*:0]const u8) c_int {
    const current = get(intf, ch, .auth_enable, 0) catch return -1;
    const b = required(current, 5) catch return -1;
    var data: [5]u8 = undefined;
    @memcpy(&data, b[0..5]);
    log.print(log.Level.debug, "%-24s: callback=0x%02x user=0x%02x operator=0x%02x admin=0x%02x oem=0x%02x", .{
        pName(.auth_enable),
        @as(c_int, data[0]),
        @as(c_int, data[1]),
        @as(c_int, data[2]),
        @as(c_int, data[3]),
        @as(c_int, data[4]),
    });
    var bits: u8 = 0;
    var it = std.mem.splitScalar(u8, std.mem.span(types), ',');
    while (it.next()) |v| {
        // C compares each remaining suffix, not just each token.
        const suffix = std.mem.span(types)[@intFromPtr(v.ptr) - @intFromPtr(types) ..];
        if (std.ascii.eqlIgnoreCase(suffix, "none")) bits |= 1 else if (std.ascii.eqlIgnoreCase(suffix, "md2")) bits |= 2 else if (std.ascii.eqlIgnoreCase(suffix, "md5")) bits |= 4 else if (std.ascii.eqlIgnoreCase(suffix, "password") or std.ascii.eqlIgnoreCase(suffix, "key")) bits |= 16 else if (std.ascii.eqlIgnoreCase(suffix, "oem")) bits |= 32 else log.print(log.Level.warning, "Invalid authentication type: %s", .{@as([*:0]const u8, @ptrCast(suffix.ptr))});
    }
    var levels = std.mem.splitScalar(u8, std.mem.span(level), ',');
    while (levels.next()) |v| {
        const suffix = std.mem.span(level)[@intFromPtr(v.ptr) - @intFromPtr(level) ..];
        if (std.ascii.eqlIgnoreCase(suffix, "callback")) data[0] = bits else if (std.ascii.eqlIgnoreCase(suffix, "user")) data[1] = bits else if (std.ascii.eqlIgnoreCase(suffix, "operator")) data[2] = bits else if (std.ascii.eqlIgnoreCase(suffix, "admin")) data[3] = bits else log.print(log.Level.warning, "Invalid authentication level: %s", .{@as([*:0]const u8, @ptrCast(suffix.ptr))});
    }
    if (c.verbose > 1) c.printbuf(&data, 5, "authtype data");
    return set(intf, ch, .auth_enable, &data, true);
}
fn cipherData(spec: [*:0]const u8, data: *[9]u8) bool {
    const s = std.mem.span(spec);
    packCipher(s, data) catch |err| {
        switch (err) {
            error.InvalidLength => log.print(log.Level.err, "Invalid privilege specification length: %d", .{@as(c_int, @intCast(s.len))}),
            error.InvalidCharacter => for (s) |char| {
                if (privNibble(char) == null) {
                    log.print(log.Level.err, "Invalid privilege specification char: %c", .{@as(c_int, char)});
                    break;
                }
            },
        }
        return false;
    };
    return true;
}
fn privNibble(char: u8) ?u8 {
    return switch (char) {
        'X' => 0,
        'c' => 1,
        'u' => 2,
        'o' => 3,
        'a' => 4,
        'O' => 5,
        else => null,
    };
}
fn packCipher(s: []const u8, data: *[9]u8) error{ InvalidLength, InvalidCharacter }!void {
    if (s.len != 15) return error.InvalidLength;
    @memset(data, 0);
    for (s, 0..) |char, i| {
        const n = privNibble(char) orelse return error.InvalidCharacter;
        data[1 + i / 2] |= if (i & 1 == 0) n else n << 4;
    }
}
fn validDestination(intf: *Intf, ch: u8, dest: u8) bool {
    const v = get(intf, ch, .destinations, 0) catch return false;
    const data = required(v, 1) catch return false;
    return dest <= data[0] & 15;
}
fn printDestination(intf: *Intf, ch: u8, dest: u8) c_int {
    const t = get(intf, ch, .dest_type, dest) catch return -1;
    const typ = required(t, 4) catch return -1;
    var b: [4]u8 = undefined;
    @memcpy(&b, typ[0..4]);
    const a = get(intf, ch, .dest_addr, dest) catch return -1;
    const addr = required(a, 13) catch return -1;
    _ = c.printf("%-24s: %d\n", @as([*:0]const u8, "Alert Destination"), @as(c_int, b[0]));
    const ack = b[1] & 0x80 != 0;
    _ = c.printf("%-24s: %s\n", @as([*:0]const u8, "Alert Acknowledge"), if (ack) @as([*:0]const u8, "Acknowledged") else "Unacknowledged");
    _ = c.printf("%-24s: %s\n", @as([*:0]const u8, "Destination Type"), switch (b[1] & 7) {
        0 => @as([*:0]const u8, "PET Trap"),
        6 => "OEM 1",
        7 => "OEM 2",
        else => "Unknown",
    });
    _ = c.printf("%-24s: %d\n", if (ack) @as([*:0]const u8, "Acknowledge Timeout") else "Retry Interval", @as(c_int, b[2]));
    _ = c.printf("%-24s: %d\n", @as([*:0]const u8, "Number of Retries"), @as(c_int, b[3] & 7));
    if (addr[1] & 0xf0 == 0) {
        _ = c.printf("%-24s: %s\n", @as([*:0]const u8, "Alert Gateway"), if (addr[2] & 1 != 0) @as([*:0]const u8, "Backup") else "Default");
        printIP("Alert IP Address", addr[3..7]);
        printMAC("Alert MAC Address", addr[7..13]);
    }
    _ = c.printf("\n");
    return 0;
}
fn printAllDestinations(intf: *Intf, ch: u8) c_int {
    const n = get(intf, ch, .destinations, 0) catch return -1;
    const bytes = required(n, 1) catch return -1;
    const count = bytes[0] & 15;
    for (0..@as(usize, count) + 1) |i| _ = printDestination(intf, ch, @intCast(i));
    return 0;
}
fn setDestination(intf: *Intf, ch: u8, dest: u8, option: [*:0]const u8, value: [*:0]const u8) c_int {
    if (!eqi(option, "ipaddr") and !eqi(option, "macaddr") and !eqi(option, "gateway") and
        !eqi(option, "ack") and !eqi(option, "type") and !eqi(option, "time") and !eqi(option, "retry"))
    {
        usage(.alert_set);
        return -1;
    }
    const address = eqi(option, "ipaddr") or eqi(option, "macaddr") or eqi(option, "gateway");
    const p: Param = if (address) .dest_addr else .dest_type;
    var ip: [4]u8 = undefined;
    var mac: [6]u8 = undefined;
    if (eqi(option, "ipaddr") and !parseIP(value, &ip)) {
        usage(.alert_set);
        return -1;
    }
    if (eqi(option, "macaddr") and !parseMac(value, &mac)) {
        usage(.alert_set);
        return -1;
    }
    const current = get(intf, ch, p, dest) catch return -1;
    const old = current.bytes orelse return -1;
    const min_len: usize = if (address) 13 else 4;
    if (old.len < min_len or old.len > 30) return -1;
    var data: [30]u8 = @splat(0);
    @memcpy(data[0..old.len], old);
    if (eqi(option, "ipaddr")) {
        @memcpy(data[3..7], &ip);
        _ = c.printf("Setting LAN Alert %d IP Address to %d.%d.%d.%d\n", @as(c_int, dest), @as(c_int, ip[0]), @as(c_int, ip[1]), @as(c_int, ip[2]), @as(c_int, ip[3]));
    } else if (eqi(option, "macaddr")) {
        @memcpy(data[7..13], &mac);
        _ = c.printf("Setting LAN Alert %d MAC Address to %s\n", @as(c_int, dest), c.mac2str(@ptrCast(&data[7])));
    } else if (eqi(option, "gateway")) {
        if (eqi(value, "def") or eqi(value, "default")) {
            data[2] = 0;
            _ = c.printf("Setting LAN Alert %d to use Default Gateway\n", @as(c_int, dest));
        } else if (eqi(value, "bak") or eqi(value, "backup")) {
            data[2] = 1;
            _ = c.printf("Setting LAN Alert %d to use Backup Gateway\n", @as(c_int, dest));
        } else {
            usage(.alert_set);
            return -1;
        }
    } else if (eqi(option, "ack")) {
        if (eqi(value, "on") or eqi(value, "yes")) {
            data[1] |= 0x80;
            _ = c.printf("Setting LAN Alert %d to Acknowledged\n", @as(c_int, dest));
        } else if (eqi(value, "off") or eqi(value, "no")) {
            data[1] &= ~@as(u8, 0x80);
            _ = c.printf("Setting LAN Alert %d to Unacknowledged\n", @as(c_int, dest));
        } else {
            usage(.alert_set);
            return -1;
        }
    } else if (eqi(option, "type")) {
        if (eqi(value, "pet")) {
            data[1] &= ~@as(u8, 7);
            _ = c.printf("Setting LAN Alert %d destination to PET Trap\n", @as(c_int, dest));
        } else if (eqi(value, "oem1")) {
            data[1] = data[1] & ~@as(u8, 7) | 6;
            _ = c.printf("Setting LAN Alert %d destination to OEM 1\n", @as(c_int, dest));
        } else if (eqi(value, "oem2")) {
            data[1] |= 7;
            _ = c.printf("Setting LAN Alert %d destination to OEM 2\n", @as(c_int, dest));
        } else {
            usage(.alert_set);
            return -1;
        }
    } else if (eqi(option, "time")) {
        data[2] = valU8(value) orelse {
            log.print(log.Level.err, "Invalid time: %s", .{value});
            return -1;
        };
        _ = c.printf("Setting LAN Alert %d timeout/retry to %d seconds\n", @as(c_int, dest), @as(c_int, data[2]));
    } else if (eqi(option, "retry")) {
        data[3] = (valU8(value) orelse {
            log.print(log.Level.err, "Invalid retry: %s", .{value});
            return -1;
        }) & 7;
        _ = c.printf("Setting LAN Alert %d number of retries to %d\n", @as(c_int, dest), @as(c_int, data[3]));
    } else {
        usage(.alert_set);
        return -1;
    }
    return set(intf, ch, p, data[0..old.len], false);
}
fn alertLan(intf: *Intf, argc: usize, argv: [*c][*c]u8) c_int {
    if (argc == 0) {
        usage(.alert_print);
        usage(.alert_set);
        return -1;
    }
    if (eqi(arg(argv, 0), "help")) {
        usage(.alert_print);
        usage(.alert_set);
        return 0;
    }
    const printing = eqi(arg(argv, 0), "print");
    if (!printing and !eqi(arg(argv, 0), "set")) return 0;
    if (!printing and argc < 5) {
        usage(.alert_set);
        return -1;
    }
    if (printing and argc > 1 and eqi(arg(argv, 1), "help")) {
        usage(.alert_print);
        return 0;
    }
    if (!printing and eqi(arg(argv, 1), "help")) {
        usage(.alert_set);
        return 0;
    }
    const ch: u8 = if (printing and argc < 2) findChannel(intf, 1) else parseChannel(arg(argv, 1)) orelse {
        log.print(log.Level.err, "Invalid channel: %s", .{arg(argv, 1)});
        return -1;
    };
    if (!lanChannel(intf, ch)) {
        log.print(log.Level.err, "Channel %d is not a LAN channel", .{@as(c_int, ch)});
        return -1;
    }
    if (printing and argc < 3) return printAllDestinations(intf, ch);
    const destination_index: usize = if (printing) 2 else 2;
    const dest = parseChannel(arg(argv, destination_index)) orelse {
        log.print(log.Level.err, "Invalid alert: %s", .{arg(argv, destination_index)});
        return -1;
    };
    if (!validDestination(intf, ch, dest)) {
        log.print(log.Level.err, "Alert %d is not a valid destination", .{@as(c_int, dest)});
        return -1;
    }
    if (printing) return printDestination(intf, ch, dest);
    return setDestination(intf, ch, dest, arg(argv, 3), arg(argv, 4));
}
fn stats(intf: *Intf, ch: u8, clear: bool) c_int {
    if (!lanChannel(intf, ch)) {
        log.print(log.Level.err, "Channel %d is not a LAN channel", .{@as(c_int, ch)});
        return -1;
    }
    const rsp = send(intf, c.IPMI_LAN_GET_STAT, &.{ ch, @intFromBool(clear) }) orelse {
        log.print(if (clear) log.Level.info else log.Level.err, "Get LAN Stats command failed", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(if (clear) log.Level.info else log.Level.err, "Get LAN Stats command failed: %s", .{ccode(rsp.ccode, false)});
        return -1;
    }
    if (clear) return 0;
    if (rsp.data_len < 18) return -1;
    if (c.verbose > 1) {
        _ = c.printf("--- Rx Stats ---\n");
        for (0..9) |i|
            _ = c.printf("%02X %02X - ", @as(c_int, rsp.data[2 * i]), @as(c_int, rsp.data[2 * i + 1]));
        _ = c.printf("\n");
    }
    const labels = [_][*:0]const u8{
        "IP Rx Packet              ", "IP Rx Header Errors       ",
        "IP Rx Address Errors      ", "IP Rx Fragmented          ",
        "IP Tx Packet              ", "UDP Rx Packet             ",
        "RMCP Rx Valid             ", "UDP Proxy Packet Received ",
        "UDP Proxy Packet Dropped  ",
    };
    for (labels, 0..) |label, i| {
        const n: c_int = @as(c_int, rsp.data[2 * i]) << 8 | rsp.data[2 * i + 1];
        _ = c.printf("%s: %d\n", label, n);
    }
    return 0;
}
fn lanpMain(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    if (argc <= 0) {
        usage(.lan);
        return -1;
    }
    const count: usize = @intCast(argc);
    const cmd = arg(argv, 0);
    if (eql(cmd, "help")) {
        usage(.lan);
        return 0;
    }
    if (eql(cmd, "printconf") or eql(cmd, "print")) {
        if (count > 2) {
            usage(.lan);
            return -1;
        }
        const ch = if (count == 2) parseChannel(arg(argv, 1)) orelse {
            log.print(log.Level.err, "Invalid channel: %s", .{arg(argv, 1)});
            return -1;
        } else findChannel(intf, 1);
        if (!lanChannel(intf, ch)) {
            log.print(log.Level.err, "Invalid channel: %d", .{@as(c_int, ch)});
            return -1;
        }
        return printLan(intf, ch);
    }
    if (eql(cmd, "set")) return setLan(intf, count - 1, argv + 1);
    if (eql(cmd, "alert")) return alertLan(intf, count - 1, argv + 1);
    if (eql(cmd, "stats")) {
        if (count < 2) {
            usage(.lan);
            return -1;
        }
        const ch = if (count == 3) parseChannel(arg(argv, 2)) orelse {
            log.print(log.Level.err, "Invalid channel: %s", .{arg(argv, 2)});
            return -1;
        } else findChannel(intf, 1);
        if (!lanChannel(intf, ch)) {
            log.print(log.Level.err, "Invalid channel: %d", .{@as(c_int, ch)});
            return -1;
        }
        if (eql(arg(argv, 1), "get")) return stats(intf, ch, false);
        if (eql(arg(argv, 1), "clear")) return stats(intf, ch, true);
        usage(.lan);
        return -1;
    }
    log.print(log.Level.notice, "Invalid LAN command: %s", .{cmd});
    return -1;
}
pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(lanpMain), @TypeOf(c.ipmi_lanp_main));
    abi.assertCallSignature(@TypeOf(findChannel), @TypeOf(c.find_lan_channel));
    @export(&lanpMain, .{ .name = "ipmi_lanp_main", .linkage = .strong });
    @export(&findChannel, .{ .name = "find_lan_channel", .linkage = .strong });
}

test "cipher privilege symbols encode in suite-number order" {
    var data: [9]u8 = undefined;
    try packCipher("cuoaOXXXXXXXXXX", &data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0x21, 0x43, 0x05, 0, 0, 0, 0, 0 }, &data);

    try packCipher("XXXXXXXXXXXXXXO", &data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 5 }, &data);
}

test "cipher privilege parser rejects malformed specifications" {
    var data: [9]u8 = undefined;
    try std.testing.expectError(error.InvalidLength, packCipher("cuoaO", &data));
    try std.testing.expectError(error.InvalidCharacter, packCipher("cuoaOXXXXXXXXX?", &data));
}

test "LAN parameter values distinguish unsupported and short BMC replies" {
    try std.testing.expectError(error.ShortResponse, required(.{ .bytes = null }, 1));
    try std.testing.expectError(error.ShortResponse, required(.{ .bytes = &.{1} }, 2));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, try required(.{ .bytes = &.{ 1, 2, 3 } }, 2));
}
fn setLan(intf: *Intf, argc: usize, argv: [*c][*c]u8) c_int {
    if (argc < 2) {
        usage(.set);
        return -1;
    }
    if (eql(arg(argv, 0), "help") or eql(arg(argv, 1), "help")) {
        usage(.set);
        return 0;
    }
    const ch = parseChannel(arg(argv, 0)) orelse {
        log.print(log.Level.err, "Invalid channel: %s", .{arg(argv, 0)});
        return -1;
    };
    if (!lanChannel(intf, ch)) {
        log.print(log.Level.err, "Channel %d is not a LAN channel!", .{@as(c_int, ch)});
        usage(.set);
        return -1;
    }
    const sub = arg(argv, 1);
    if (eql(sub, "user")) {
        var access = std.mem.zeroes(c.struct_user_access_t);
        access.channel = ch;
        access.user_id = 1;
        access.privilege_limit = 4;
        if (c.eval_ccode(c._ipmi_set_user_access(ci(intf), &access, 1)) != 0) {
            log.print(log.Level.err, "Set User Access for channel %d failed", .{@as(c_int, ch)});
            return -1;
        }
        _ = c.printf("Set User Access for channel %d was successful.", @as(c_int, ch));
        return 0;
    }
    if (eql(sub, "access")) {
        if (argc < 3) {
            usage(.access);
            return -1;
        }
        if (eql(arg(argv, 2), "help")) {
            usage(.access);
            return 0;
        }
        if (eql(arg(argv, 2), "on")) return channelAccess(intf, ch, true, false);
        if (eql(arg(argv, 2), "off")) return channelAccess(intf, ch, false, false);
        usage(.access);
        return -1;
    }
    if (eql(sub, "arp")) {
        if (argc < 3) {
            usage(.arp);
            return -1;
        }
        const opt = arg(argv, 2);
        if (eql(opt, "help")) {
            usage(.arp);
            return 0;
        }
        if (eql(opt, "interval")) {
            if (argc < 4) {
                usage(.arp);
                return -1;
            }
            const n = valU8(arg(argv, 3)) orelse {
                log.print(log.Level.err, "Given ARP interval '%s' is invalid.", .{arg(argv, 3)});
                return -1;
            };
            const v = get(intf, ch, .grat, 0) catch return -1;
            const b = required(v, 1) catch return -1;
            var interval: u8 = b[0];
            var rc: c_int = 0;
            if (n != 0) {
                if (n > 127) {
                    log.print(log.Level.err, "Given ARP interval '%u' is too big.", .{@as(c_uint, n)});
                    return -1;
                }
                interval = n * 2 - 1;
                rc = set(intf, ch, .grat, &.{interval}, true);
            }
            _ = c.printf("BMC-generated Gratuitous ARP interval:  %.1f seconds\n", @as(f64, @floatFromInt((@as(u16, interval) + 1) / 2)));
            return rc;
        }
        if (eql(opt, "generate") or eql(opt, "respond")) {
            if (argc < 4) {
                usage(.arp);
                return -1;
            }
            const on = eql(arg(argv, 3), "on");
            if (!on and !eql(arg(argv, 3), "off")) {
                usage(.arp);
                return -1;
            }
            const v = get(intf, ch, .arp, 0) catch return -1;
            const b = required(v, 1) catch return -1;
            const bit: u8 = if (eql(opt, "generate")) 1 else 2;
            const flags = if (on) b[0] | bit else b[0] & ~bit;
            _ = c.printf("%sabling BMC-generated %s\n", if (on) @as([*:0]const u8, "En") else "Dis", if (bit == 1) @as([*:0]const u8, "Gratuitous ARPs") else "ARP responses");
            return set(intf, ch, .arp, &.{flags}, true);
        }
        usage(.arp);
        return 0;
    }
    if (eql(sub, "auth")) {
        if (argc < 3) {
            usage(.auth);
            return -1;
        }
        if (eql(arg(argv, 2), "help")) {
            usage(.auth);
            return 0;
        }
        if (argc < 4) return -1;
        return authSet(intf, ch, arg(argv, 2), arg(argv, 3));
    }
    if (eql(sub, "ipsrc")) {
        if (argc < 3) {
            usage(.ipsrc);
            return -1;
        }
        const value = arg(argv, 2);
        if (eql(value, "help")) {
            usage(.ipsrc);
            return 0;
        }
        const src: u8 = if (eql(value, "none")) 0 else if (eql(value, "static")) 1 else if (eql(value, "dhcp")) 2 else if (eql(value, "bios")) 3 else {
            usage(.ipsrc);
            return -1;
        };
        return set(intf, ch, .source, &.{src}, true);
    }
    if (eql(sub, "password")) {
        const password: [*c]const u8 = if (argc > 2) argv[2] else null;
        if (c.eval_ccode(c._ipmi_set_user_password(ci(intf), 1, c.IPMI_PASSWORD_SET_PASSWORD, password, 0)) != 0) {
            log.print(log.Level.err, "Unable to Set LAN Password for user %d", .{@as(c_int, 1)});
            return -1;
        }
        c.ipmi_intf_session_set_password(ci(intf), @constCast(password));
        _ = c.printf("Password %s for user 1\n", if (password != null) @as([*:0]const u8, "set") else "cleared");
        return 0;
    }
    if (eql(sub, "snmp")) {
        if (argc < 3) {
            usage(.snmp);
            return -1;
        }
        if (eql(arg(argv, 2), "help")) {
            usage(.snmp);
            return 0;
        }
        var data: [19]u8 = @splat(0);
        const community = std.mem.span(arg(argv, 2));
        @memcpy(data[0..@min(community.len, 18)], community[0..@min(community.len, 18)]);
        _ = c.printf("Setting LAN %s to %s\n", pName(.snmp), &data);
        return set(intf, ch, .snmp, data[0..18], true);
    }
    if (eql(sub, "ipaddr") or eql(sub, "netmask") or eql(sub, "macaddr") or eql(sub, "defgw") or eql(sub, "bakgw")) {
        const gateway = eql(sub, "defgw") or eql(sub, "bakgw");
        if (gateway and argc < 4) {
            if (eql(sub, "defgw")) usage(.defgw) else usage(.bakgw);
            return -1;
        }
        if (gateway and eql(arg(argv, 2), "help")) {
            if (eql(sub, "defgw")) usage(.defgw) else usage(.bakgw);
            return 0;
        }
        if (!gateway and argc != 3) {
            usage(.set);
            return -1;
        }
        const is_mac = if (gateway) eql(arg(argv, 2), "macaddr") else eql(sub, "macaddr");
        const is_ip = if (gateway) eql(arg(argv, 2), "ipaddr") else true;
        if (!is_mac and !is_ip) {
            usage(.set);
            return -1;
        }
        const text = arg(argv, if (gateway) 3 else 2);
        if (is_mac) {
            var b: [6]u8 = undefined;
            if (!parseMac(text, &b)) {
                if (gateway) usage(.set);
                return -1;
            }
            const p: Param = if (eql(sub, "defgw")) .gateway_mac else if (eql(sub, "bakgw")) .backup_mac else .mac;
            printSetting(ch, p, &b);
            return set(intf, ch, p, &b, true);
        }
        var b: [4]u8 = undefined;
        if (!parseIP(text, &b)) {
            if (gateway) usage(.set);
            return -1;
        }
        const p: Param = if (eql(sub, "defgw")) .gateway else if (eql(sub, "bakgw")) .backup else if (eql(sub, "netmask")) .mask else .ip;
        printSetting(ch, p, &b);
        return set(intf, ch, p, &b, true);
    }
    if (eql(sub, "vlan")) {
        if (argc < 4) {
            usage(.vlan);
            return -1;
        }
        if (eql(arg(argv, 2), "help")) {
            usage(.vlan);
            return 0;
        }
        if (eql(arg(argv, 2), "id")) {
            _ = vlanSet(intf, ch, arg(argv, 3));
            return 0; // The C dispatcher discards both VLAN helper return values.
        }
        if (eql(arg(argv, 2), "priority")) {
            const n = valInt(arg(argv, 3)) orelse {
                log.print(log.Level.err, "Given VLAN priority '%s' is invalid.", .{arg(argv, 3)});
                return 0;
            };
            if (n < 0 or n > 7) {
                log.print(log.Level.notice, "VLAN priority must be between 0 and 7.", .{});
                return 0;
            }
            _ = set(intf, ch, .priority, &.{@intCast(n)}, true);
            return 0;
        }
        usage(.vlan);
        return -1;
    }
    if (eql(sub, "alert")) {
        if (argc < 3) {
            log.print(log.Level.notice, "LAN set alert must be 'on' or 'off'", .{});
            return -1;
        }
        const on = eql(arg(argv, 2), "on") or eql(arg(argv, 2), "enable");
        if (!on and !eql(arg(argv, 2), "off") and !eql(arg(argv, 2), "disable")) {
            log.print(log.Level.notice, "LAN set alert must be 'on' or 'off'", .{});
            return 0;
        }
        _ = c.printf("%s PEF alerts for LAN channel %d\n", if (on) @as([*:0]const u8, "Enabling") else "Disabling", @as(c_int, ch));
        return channelAccess(intf, ch, on, true);
    }
    if (eql(sub, "cipher_privs")) {
        if (argc != 3) {
            usage(.cipher);
            return -1;
        }
        var data: [9]u8 = undefined;
        if (eql(arg(argv, 2), "help") or !cipherData(arg(argv, 2), &data)) {
            usage(.cipher);
            return 0;
        }
        return set(intf, ch, .cipher_priv, &data, true);
    }
    if (eql(sub, "bad_pass_thresh")) {
        if (argc == 3 and eql(arg(argv, 2), "help")) {
            usage(.bad_pass);
            return 0;
        }
        if (argc < 6) {
            usage(.bad_pass);
            return -1;
        }
        const threshold = valU8(arg(argv, 2)) orelse {
            usage(.bad_pass);
            return -1;
        };
        const flag = valU8(arg(argv, 3)) orelse {
            usage(.bad_pass);
            return -1;
        };
        const reset = valU16(arg(argv, 4)) orelse {
            usage(.bad_pass);
            return -1;
        };
        const lockout = valU16(arg(argv, 5)) orelse {
            usage(.bad_pass);
            return -1;
        };
        if (flag > 1) {
            usage(.bad_pass);
            return -1;
        }
        return set(intf, ch, .threshold, &.{
            flag,               threshold,               @truncate(reset), @truncate(reset >> 8),
            @truncate(lockout), @truncate(lockout >> 8),
        }, true);
    }
    usage(.set);
    return -1;
}
