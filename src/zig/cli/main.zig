//! CLI option parser, session setup and command dispatcher from lib/ipmi_main.c.
//! libc's getopt is retained for its GNU argument permutation, diagnostic
//! stream, optind/optarg state and in-place mutation of argv.

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const types = @import("../intf/intf.zig");
const Intf = types.Intf;
const Cmd = types.Cmd;
const IntfSupport = types.IntfSupport;

var main_intf: ?*Intf = null;

fn freeSlot(slot: *?[*:0]u8) void {
    if (slot.*) |old| c.free(old);
    slot.* = null;
}

fn replace(slot: *?[*:0]u8, value: [*c]const u8, progname: [*:0]const u8) bool {
    freeSlot(slot);
    const copy = c.strdup(value);
    if (copy == null) {
        log.print(log.Level.err, "%s: malloc failure", .{progname});
        return false;
    }
    slot.* = @ptrCast(copy);
    return true;
}

fn passwordFileRead(filename: [*c]u8) ?[*:0]u8 {
    const raw = c.malloc(21) orelse {
        log.print(log.Level.err, "ipmitool: malloc failure", .{});
        return null;
    };
    const pass: [*c]u8 = @ptrCast(raw);
    @memset(pass[0..21], 0);
    const fp = c.ipmi_open_file(filename, 0);
    if (fp == null) {
        log.print(log.Level.err, "Unable to open password file %s", .{filename});
        c.free(raw);
        return null;
    }
    if (c.fgets(pass, 21, fp) == null) {
        log.print(log.Level.err, "Unable to read password from file %s", .{filename});
        c.free(raw);
        _ = c.fclose(fp);
        return null;
    }
    const n = c.strcspn(pass, "\r\n\t");
    if (n > 0) pass[n] = 0;
    _ = c.fclose(fp);
    return @ptrCast(pass);
}

fn cmdPrint(cmdlist: ?[*]Cmd) callconv(.c) void {
    const commands = cmdlist orelse return;
    var header = false;
    var i: usize = 0;
    while (commands[i].func != null) : (i += 1) {
        const desc = commands[i].desc orelse continue;
        if (!header) {
            log.print(log.Level.notice, "Commands:", .{});
            header = true;
        }
        log.print(log.Level.notice, "\t%-12s  %s", .{ commands[i].name, desc });
    }
    log.print(log.Level.notice, "", .{});
}

fn cmdRun(intf: *Intf, name: ?[*:0]u8, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
    const commands = intf.cmdlist.?;
    if (name == null) {
        if (commands[0].func == null or commands[0].name == null) return -1;
        if (c.strcmp(commands[0].name, "default") == 0)
            return commands[0].func.?(intf, 0, null);
        log.print(log.Level.err, "No command provided!", .{});
        cmdPrint(commands);
        return -1;
    }
    var i: usize = 0;
    while (commands[i].func != null) : (i += 1) {
        if (c.strcmp(name, commands[i].name) == 0) break;
    }
    if (commands[i].func == null) {
        if (c.strcmp(commands[0].name, "default") == 0)
            return commands[0].func.?(intf, argc + 1, @ptrCast(argv.? - 1));
        log.print(log.Level.err, "Invalid command: %s", .{name});
        cmdPrint(commands);
        return -1;
    }
    return commands[i].func.?(intf, argc, argv);
}

const common_usage = [_][*:0]const u8{
    "       -h             This help",
    "       -V             Show version information",
    "       -v             Verbose (can use multiple times)",
    "       -c             Display output in comma separated format",
    "       -d N           Specify a /dev/ipmiN device to use (default=0)",
    "       -I intf        Interface to use",
    "       -H hostname    Remote host name for LAN interface",
    "       -p port        Remote RMCP port [default=623]",
    "       -U username    Remote session username",
    "       -f file        Read remote session password from file",
    "       -z size        Change Size of Communication Channel (OEM)",
    "       -S sdr         Use local file for remote SDR cache",
    "       -D tty:b[:s]   Specify the serial device, baud rate to use",
    "                      and, optionally, specify that interface is the system one",
    "       -4             Use only IPv4",
    "       -6             Use only IPv6",
};

const extra_usage = [_][*:0]const u8{
    "       -a             Prompt for remote password",
    "       -Y             Prompt for the Kg key for IPMIv2 authentication",
    "       -e char        Set SOL escape character",
    "       -C ciphersuite Cipher suite to be used by lanplus interface",
    "       -k key         Use Kg key for IPMIv2 authentication",
    "       -y hex_key     Use hexadecimal-encoded Kg key for IPMIv2 authentication",
    "       -L level       Remote session privilege level [default=ADMINISTRATOR]",
    "                      Append a '+' to use name/privilege lookup in RAKP1",
    "       -A authtype    Force use of auth type NONE, PASSWORD, MD2, MD5 or OEM",
    "       -P password    Remote session password",
    "       -E             Read password from IPMI_PASSWORD environment variable",
    "       -K             Read kgkey from IPMI_KGKEY environment variable",
    "       -m address     Set local IPMB address",
    "       -b channel     Set destination channel for bridged request",
    "       -t address     Bridge request to remote target address",
    "       -B channel     Set transit channel for bridged request (dual bridge)",
    "       -T address     Set transit address for bridge request (dual bridge)",
    "       -l lun         Set destination lun for raw commands",
    "       -o oemtype     Setup for OEM (use 'list' to see available OEM types)",
    "       -O seloem      Use file for OEM SEL event descriptions",
    "       -N seconds     Specify timeout for lan [default=2] / lanplus [default=1] interface",
    "       -R retry       Set the number of retries for lan/lanplus interface [default=4]",
    "       -Z             Display all dates in UTC",
};

fn optionUsage(progname: [*:0]const u8, cmdlist: ?[*]Cmd, intflist: ?[*]IntfSupport) void {
    log.print(log.Level.notice, "%s version %s\n", .{ progname, c.VERSION });
    log.print(log.Level.notice, "usage: %s [options...] <command>\n", .{progname});
    for (common_usage) |line| log.print(log.Level.notice, "%s", .{line});
    if (@hasDecl(c, "ENABLE_ALL_OPTIONS")) {
        for (extra_usage) |line| log.print(log.Level.notice, "%s", .{line});
    }
    log.print(log.Level.notice, "", .{});
    c.ipmi_intf_print(@ptrCast(intflist));
    if (cmdlist != null) cmdPrint(cmdlist);
}

fn catchSigint() callconv(.c) void {
    if (main_intf) |intf| {
        _ = c.printf("\nSIGN INT: Close Interface %s\n", @as([*c]const u8, @ptrCast(&intf.desc)));
        intf.ssn_params.retry = 1;
        intf.close.?(intf);
    }
    c.exit(-1);
}

fn sigintHandler(_: c_int) callconv(.c) void {
    catchSigint();
}

fn acquireIpmbAddress(intf: *Intf) u8 {
    if (intf.picmg_avail != 0) return c.ipmi_picmg_ipmb_address(@ptrCast(intf));
    if (intf.vita_avail != 0) return c.ipmi_vita_ipmb_address(@ptrCast(intf));
    return 0;
}

fn main(argc: c_int, argv: [*c][*c]u8, cmdlist: ?[*]Cmd, intflist: ?[*]IntfSupport) callconv(.c) c_int {
    var privlvl: c_int = 0;
    var target_addr: u8 = 0;
    var target_channel: u8 = 0;
    var u8tmp: u8 = 0;
    var transit_addr: u8 = 0;
    var transit_channel: u8 = 0;
    var target_lun: u8 = 0;
    var arg_addr: u8 = 0;
    var addr: u8 = 0;
    var long_packet_size: u16 = 0;
    var long_packet_set = false;
    var lookupbit: u8 = 0x10;
    var retry: c_int = 0;
    var timeout: u32 = 0;
    var authtype: c_int = -1;
    var hostname: ?[*:0]u8 = null;
    var username: ?[*:0]u8 = null;
    var password: ?[*:0]u8 = null;
    var intfname: ?[*:0]u8 = null;
    var oemtype: ?[*:0]u8 = null;
    var sdrcache: ?[*:0]u8 = null;
    var kgkey: [types.kg_buffer_size]u8 = @splat(0);
    var seloem: ?[*:0]u8 = null;
    var port: c_int = 0;
    var devnum: c_int = 0;
    var cipher_suite_id: c.enum_cipher_suite_ids = c.IPMI_LANPLUS_CIPHER_SUITE_RESERVED;
    var rc: c_int = -1;
    var ai_family: c_int = c.AF_UNSPEC;
    var sol_escape_char: u8 = c.SOL_ESCAPE_CHARACTER_DEFAULT;
    var devfile: ?[*:0]u8 = null;

    _ = c.setlocale(c.LC_ALL, "");
    const base: [*c]u8 = c.strrchr(argv[0], '/');
    const progname: [*:0]u8 = @ptrCast(if (base == null) argv[0] else base + 1);
    _ = c.signal(c.SIGINT, &sigintHandler);
    c.log_init(progname, 0, 0);
    defer {
        c.log_halt();
        freeSlot(&intfname);
        freeSlot(&hostname);
        freeSlot(&username);
        freeSlot(&password);
        freeSlot(&oemtype);
        freeSlot(&seloem);
        freeSlot(&sdrcache);
        freeSlot(&devfile);
        c.ipmi_oem_info_free();
    }

    const option_string: [*:0]const u8 = if (@hasDecl(c, "ENABLE_ALL_OPTIONS"))
        "I:46hVvcgsEKYao:H:d:P:f:U:p:C:L:A:t:T:m:z:S:l:b:B:e:k:y:O:R:N:D:Z"
    else
        "I:46hVvcH:f:U:p:d:S:D:";

    while (true) {
        const opt = c.getopt(argc, argv, option_string);
        if (opt == -1) break;
        const arg = c.optarg;
        switch (opt) {
            'I' => {
                if (!replace(&intfname, arg, progname)) return rc;
                if (intflist) |list| {
                    var found = false;
                    var j: usize = 0;
                    while (list[j].name != null) : (j += 1) {
                        if (c.strcmp(list[j].name, intfname) == 0 and list[j].supported != 0)
                            found = true;
                    }
                    if (!found) {
                        log.print(log.Level.err, "Interface %s not supported", .{intfname});
                        return rc;
                    }
                }
            },
            'h' => {
                optionUsage(progname, cmdlist, intflist);
                return 0;
            },
            'V' => {
                _ = c.printf("%s version %s\n", progname, c.VERSION);
                return 0;
            },
            'd' => {
                if (c.str2int(arg, &devnum) != 0) {
                    log.print(log.Level.err, "Invalid parameter given or out of range for '-d'.", .{});
                    return -1;
                }
                if (devnum < 0) {
                    log.print(log.Level.err, "Device number %i is out of range.", .{devnum});
                    return -1;
                }
            },
            'p' => {
                if (c.str2int(arg, &port) != 0) {
                    log.print(log.Level.err, "Invalid parameter given or out of range for '-p'.", .{});
                    return -1;
                }
                if (port < 0 or port > 65535) {
                    log.print(log.Level.err, "Port number %i is out of range.", .{port});
                    return -1;
                }
            },
            'C' => if (@hasDecl(c, "IPMI_INTF_LANPLUS")) {
                if (c.str2uchar(arg, &u8tmp) != 0) {
                    log.print(log.Level.err, "Invalid parameter given or out of range [0-255] for '-C'.", .{});
                    return -1;
                }
                cipher_suite_id = u8tmp;
            } else {
                optionUsage(progname, cmdlist, intflist);
                return rc;
            },
            'v' => {
                c.verbose += 1;
                c.log_level_set(c.verbose);
                if (c.verbose == 2) log.print(log.Level.debug, "%s version %s\n", .{ progname, c.VERSION });
            },
            'c' => c.csv_output = 1,
            'H' => if (!replace(&hostname, arg, progname)) return rc,
            'f' => {
                freeSlot(&password);
                password = passwordFileRead(arg);
                if (password == null) log.print(log.Level.err, "Unable to read password from file %s", .{arg});
            },
            'a' => {
                const entered = prompt("Password: ");
                if (entered != null and !replace(&password, entered, progname)) return rc;
            },
            'k' => {
                @memset(&kgkey, 0);
                _ = c.strncpy(@ptrCast(&kgkey), arg, kgkey.len - 1);
            },
            'K' => {
                if (c.getenv("IPMI_KGKEY")) |value| {
                    @memset(&kgkey, 0);
                    _ = c.strncpy(@ptrCast(&kgkey), value, kgkey.len - 1);
                } else log.print(log.Level.warning, "Unable to read kgkey from environment", .{});
            },
            'y' => {
                @memset(&kgkey, 0);
                rc = c.ipmi_parse_hex(arg, @ptrCast(&kgkey), kgkey.len - 1);
                if (rc == -1) {
                    log.print(log.Level.err, "Number of Kg key characters is not even", .{});
                    return rc;
                } else if (rc == -3) {
                    log.print(log.Level.err, "Kg key is not hexadecimal number", .{});
                    return rc;
                } else if (rc > kgkey.len - 1) {
                    log.print(log.Level.err, "Kg key is too long", .{});
                    return rc;
                }
            },
            'Y' => {
                if (prompt("Key: ")) |entered| {
                    @memset(&kgkey, 0);
                    _ = c.strncpy(@ptrCast(&kgkey), entered, kgkey.len - 1);
                }
            },
            'U' => {
                freeSlot(&username);
                if (c.strlen(arg) > 16) {
                    log.print(log.Level.err, "Username is too long (> 16 bytes)", .{});
                    return rc;
                }
                if (!replace(&username, arg, progname)) return rc;
            },
            'S' => if (!replace(&sdrcache, arg, progname)) return rc,
            'D' => if (!replace(&devfile, arg, progname)) return rc,
            '4', '6' => {
                const wanted = if (opt == '4') c.AF_INET else c.AF_INET6;
                if (ai_family == c.AF_UNSPEC) {
                    ai_family = wanted;
                } else {
                    if (ai_family != wanted) {
                        log.print(log.Level.err, if (opt == '4')
                            "Parameter is mutually exclusive with -6."
                        else
                            "Parameter is mutually exclusive with -4.", .{});
                    } else {
                        log.print(log.Level.err, if (opt == '4')
                            "Multiple -4 parameters given."
                        else
                            "Multiple -6 parameters given.", .{});
                    }
                    return -1;
                }
            },
            'o' => {
                if (!replace(&oemtype, arg, progname)) return rc;
                if (c.strcmp(oemtype, "list") == 0 or c.strcmp(oemtype, "help") == 0) {
                    c.ipmi_oem_print();
                    return 0;
                }
            },
            'g', 's' => {
                freeSlot(&oemtype);
                oemtype = @ptrCast(c.strdup(if (opt == 'g') "intelwv2" else "supermicro"));
            },
            'P' => {
                if (!replace(&password, arg, progname)) return rc;
                _ = c.memset(arg, 'X', c.strlen(arg));
            },
            'E' => {
                if (c.getenv("IPMITOOL_PASSWORD") orelse c.getenv("IPMI_PASSWORD")) |value| {
                    if (!replace(&password, value, progname)) return rc;
                } else log.print(log.Level.warning, "Unable to read password from environment", .{});
            },
            'L' => {
                const n = c.strlen(arg);
                if (n > 0 and arg[n - 1] == '+') {
                    lookupbit = 0;
                    arg[n - 1] = 0;
                }
                privlvl = c.str2val(arg, c.ipmi_privlvl_vals);
                if (privlvl == 0xff) log.print(log.Level.warning, "Invalid privilege level %s", .{arg});
            },
            'A' => authtype = c.str2val(arg, c.ipmi_authtype_session_vals),
            't' => if (!parseByte(arg, &target_addr, 't')) return -1,
            'b' => if (!parseByte(arg, &target_channel, 'b')) return -1,
            'T' => if (!parseByte(arg, &transit_addr, 'T')) return -1,
            'B' => if (!parseByte(arg, &transit_channel, 'B')) return -1,
            'l' => if (!parseByte(arg, &target_lun, 'l')) return 1,
            'm' => if (!parseByte(arg, &arg_addr, 'm')) return -1,
            'e' => sol_escape_char = arg[0],
            'O' => if (!replace(&seloem, arg, progname)) return rc,
            'z' => {
                if (c.str2ushort(arg, &long_packet_size) != 0) {
                    log.print(log.Level.err, "Invalid parameter given or out of range for '-z'.", .{});
                    return -1;
                }
            },
            'R' => {
                if (c.str2int(arg, &retry) != 0 or retry < 0) {
                    log.print(log.Level.err, "Invalid parameter given or out of range for '-R'.", .{});
                    return -1;
                }
            },
            'N' => {
                if (c.str2uint(arg, &timeout) != 0) {
                    log.print(log.Level.err, "Invalid parameter given or out of range for '-N'.", .{});
                    return -1;
                }
            },
            'Z' => c.time_in_utc = true,
            else => {
                optionUsage(progname, cmdlist, intflist);
                return rc;
            },
        }
    }

    const start: usize = @intCast(c.optind);
    if (argc - c.optind > 0 and c.strcmp(argv[start], "help") == 0) {
        cmdPrint(cmdlist);
        return 0;
    }
    if (hostname != null and password == null and
        (authtype != c.IPMI_SESSION_AUTHTYPE_NONE or authtype < 0))
    {
        if (prompt("Password: ")) |entered| {
            if (!replace(&password, entered, progname)) return rc;
        }
    }
    if (intfname == null and hostname != null and !replace(&intfname, "lan", progname)) return rc;
    if (password) |pass| {
        if (intfname) |selected| {
            if (c.strcmp(selected, "lan") == 0 and c.strlen(pass) > 16) {
                log.print(log.Level.err, "%s: password is longer than 16 bytes.", .{selected});
                return -1;
            } else if (c.strcmp(selected, "lanplus") == 0 and c.strlen(pass) > 20) {
                log.print(log.Level.err, "%s: password is longer than 20 bytes.", .{selected});
                return -1;
            }
        }
    }
    const intf = @as(?*Intf, @ptrCast(c.ipmi_intf_load(@ptrCast(intfname)))) orelse {
        log.print(log.Level.err, "Error loading interface %s", .{intfname});
        return rc;
    };
    main_intf = intf;
    c.ipmi_oem_info_init();
    if (oemtype) |oem| {
        if (c.ipmi_oem_setup(@ptrCast(intf), oem) < 0) {
            log.print(log.Level.err, "OEM setup for \"%s\" failed", .{oem});
            return rc;
        }
    }

    if (hostname) |value| c.ipmi_intf_session_set_hostname(@ptrCast(intf), value);
    if (username) |value| c.ipmi_intf_session_set_username(@ptrCast(intf), value);
    if (password) |value| c.ipmi_intf_session_set_password(@ptrCast(intf), value);
    c.ipmi_intf_session_set_kgkey(@ptrCast(intf), @ptrCast(&kgkey));
    if (port > 0) c.ipmi_intf_session_set_port(@ptrCast(intf), port);
    if (authtype >= 0) c.ipmi_intf_session_set_authtype(@ptrCast(intf), @intCast(authtype));
    c.ipmi_intf_session_set_privlvl(@ptrCast(intf), if (privlvl > 0) @intCast(privlvl) else c.IPMI_SESSION_PRIV_ADMIN);
    if (retry > 0) c.ipmi_intf_session_set_retry(@ptrCast(intf), retry);
    if (timeout > 0) c.ipmi_intf_session_set_timeout(@ptrCast(intf), timeout);
    c.ipmi_intf_session_set_lookupbit(@ptrCast(intf), lookupbit);
    c.ipmi_intf_session_set_sol_escape_char(@ptrCast(intf), @bitCast(sol_escape_char));
    if (@hasDecl(c, "IPMI_INTF_LANPLUS"))
        c.ipmi_intf_session_set_cipher_suite_id(@ptrCast(intf), cipher_suite_id);

    intf.devnum = @truncate(@as(c_uint, @bitCast(devnum)));
    intf.devfile = devfile;
    intf.ai_family = ai_family;
    intf.my_addr = if (arg_addr != 0) arg_addr else c.IPMI_BMC_SLAVE_ADDR;
    if (intf.open) |open| {
        if (open(intf) < 0) return rc;
    }
    if (c.ipmi_oem_active(@ptrCast(intf), "i82571spt") == 0) {
        if (c.picmg_discover(@ptrCast(intf)) != 0) {
            intf.picmg_avail = 1;
        } else if (c.vita_discover(@ptrCast(intf)) != 0) {
            intf.vita_avail = 1;
        }
    }
    if (arg_addr != 0) {
        addr = arg_addr;
    } else if (c.ipmi_oem_active(@ptrCast(intf), "i82571spt") == 0) {
        log.print(log.Level.debug, "Acquire IPMB address", .{});
        addr = acquireIpmbAddress(intf);
        log.print(log.Level.info, "Discovered IPMB address 0x%x", .{@as(c_uint, addr)});
    }
    if (addr != 0 and addr != intf.my_addr) {
        if (intf.set_my_addr) |set_addr| _ = set_addr(intf, addr);
        intf.my_addr = addr;
    }
    intf.target_addr = intf.my_addr;
    if (transit_addr > 0 or target_addr > 0) {
        if ((transit_addr != 0 or transit_channel != 0) and target_addr == 0) {
            log.print(log.Level.err, "Transit address/channel %#x/%#x ignored. Target address must be specified!", .{ @as(c_uint, transit_addr), @as(c_uint, transit_channel) });
            return rc;
        }
        intf.target_addr = target_addr;
        intf.target_channel = target_channel;
        intf.transit_addr = transit_addr;
        intf.transit_channel = transit_channel;
        c.ipmi_intf_session_set_privlvl(@ptrCast(intf), c.IPMI_SESSION_PRIV_ADMIN);
        intf.target_ipmb_addr = acquireIpmbAddress(intf);
        log.print(log.Level.debug, "Specified addressing     Target  %#x:%#x Transit %#x:%#x", .{ intf.target_addr, @as(c_uint, intf.target_channel), intf.transit_addr, @as(c_uint, intf.transit_channel) });
        if (intf.target_ipmb_addr != 0) {
            log.print(log.Level.info, "Discovered Target IPMB-0 address %#x", .{@as(c_uint, intf.target_ipmb_addr)});
        }
    }
    intf.target_lun = target_lun;
    log.print(log.Level.debug, "Interface address: my_addr %#x transit %#x:%#x target %#x:%#x ipmb_target %#x\n", .{ intf.my_addr, intf.transit_addr, @as(c_uint, intf.transit_channel), intf.target_addr, @as(c_uint, intf.target_channel), @as(c_uint, intf.target_ipmb_addr) });

    if (sdrcache) |value| _ = c.ipmi_sdr_list_cache_fromfile(value);
    if (seloem) |value| _ = c.ipmi_sel_oem_init(value);
    if (long_packet_size != 0) {
        if (c.ipmi_oem_active(@ptrCast(intf), "kontron") == 0 or
            c.ipmi_kontronoem_set_large_buffer(@ptrCast(intf), @truncate(long_packet_size)) == 0)
        {
            _ = c.printf("Setting large buffer to %i\n", @as(c_int, long_packet_size));
            long_packet_set = true;
            c.ipmi_intf_set_max_request_data_size(@ptrCast(intf), long_packet_size);
        }
    }
    intf.cmdlist = cmdlist;
    if (argc - c.optind > 0) {
        rc = cmdRun(intf, @ptrCast(argv[start]), argc - c.optind - 1, @ptrCast(argv + start + 1));
    } else {
        rc = cmdRun(intf, null, 0, null);
    }
    if (long_packet_set and c.ipmi_oem_active(@ptrCast(intf), "kontron") != 0)
        _ = c.ipmi_kontronoem_set_large_buffer(@ptrCast(intf), 0);
    c.ipmi_cleanup(@ptrCast(intf));
    if (intf.opened != 0) {
        if (intf.close) |close| close(intf);
    }
    return rc;
}

fn prompt(message: [*:0]const u8) [*c]u8 {
    if (@hasDecl(c, "HAVE_GETPASSPHRASE")) return c.getpassphrase(message);
    return c.getpass(message);
}

fn parseByte(arg: [*c]const u8, output: *u8, comptime flag: u8) bool {
    if (c.str2uchar(arg, output) == 0) return true;
    log.print(log.Level.err, "Invalid parameter given or out of range for '-" ++ .{flag} ++ "'.", .{});
    return false;
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(main), @TypeOf(c.ipmi_main));
    abi.assertCallSignature(@TypeOf(cmdPrint), @TypeOf(c.ipmi_cmd_print));
    abi.assertCallSignature(@TypeOf(cmdRun), @TypeOf(c.ipmi_cmd_run));
    abi.assertCallSignature(@TypeOf(catchSigint), @TypeOf(c.ipmi_catch_sigint));
    @export(&main, .{ .name = "ipmi_main", .linkage = .strong });
    @export(&cmdPrint, .{ .name = "ipmi_cmd_print", .linkage = .strong });
    @export(&cmdRun, .{ .name = "ipmi_cmd_run", .linkage = .strong });
    @export(&catchSigint, .{ .name = "ipmi_catch_sigint", .linkage = .strong });
}
