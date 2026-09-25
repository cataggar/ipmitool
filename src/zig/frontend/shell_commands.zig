//! Non-interactive shell commands, swapped with src/ipmishell.c by ipmishell.
const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");
const frontend_log = @import("logging.zig");
const shell = @import("ipmishell.zig");

const allocator = std.heap.c_allocator;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn echoMain(_: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    for (0..@intCast(@max(argc, 0))) |i| _ = c.printf("%s ", argv[i]);
    _ = c.printf("\n");
    return 0;
}

fn setUsage() void {
    frontend_log.print(log.Level.notice, "Usage: set <option> <value>\n", .{});
    frontend_log.print(log.Level.notice, "Options are:", .{});
    frontend_log.print(log.Level.notice, "    hostname <host>        Session hostname", .{});
    frontend_log.print(log.Level.notice, "    username <user>        Session username", .{});
    frontend_log.print(log.Level.notice, "    password <pass>        Session password", .{});
    frontend_log.print(log.Level.notice, "    privlvl <level>        Session privilege level force", .{});
    frontend_log.print(log.Level.notice, "    authtype <type>        Authentication type force", .{});
    frontend_log.print(log.Level.notice, "    localaddr <addr>       Local IPMB address", .{});
    frontend_log.print(log.Level.notice, "    targetaddr <addr>      Remote target IPMB address", .{});
    frontend_log.print(log.Level.notice, "    port <port>            Remote RMCP port", .{});
    frontend_log.print(log.Level.notice, "    csv [level]            enable output in comma separated format", .{});
    frontend_log.print(log.Level.notice, "    verbose [level]        Verbose level", .{});
    frontend_log.print(log.Level.notice, "", .{});
}

fn setMain(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    if (argc <= 0 or eq(std.mem.span(argv[0]), "help")) {
        setUsage();
        return -1;
    }
    const name = std.mem.span(argv[0]);
    if (eq(name, "verbose") or eq(name, "csv")) {
        const value = if (eq(name, "verbose")) &c.verbose else &c.csv_output;
        if (argc > 1) {
            if (c.str2int(argv[1], value) != 0) {
                frontend_log.print(log.Level.err, "Given %s '%s' argument is invalid.", .{ argv[0], argv[1] });
                return -1;
            }
        } else if (eq(name, "verbose")) {
            value.* +%= 1;
        } else value.* = 1;
        return 0;
    }
    if (argc == 1) {
        setUsage();
        return -1;
    }
    const value = argv[1];
    if (eq(name, "host") or eq(name, "hostname")) {
        c.ipmi_intf_session_set_hostname(@ptrCast(intf), value);
        if (intf.session == null) {
            frontend_log.print(log.Level.err, "Failed to set session hostname.", .{});
            return -1;
        }
        _ = c.printf("Set session hostname to %s\n", intf.ssn_params.hostname);
    } else if (eq(name, "user") or eq(name, "username")) {
        c.ipmi_intf_session_set_username(@ptrCast(intf), value);
        if (intf.session == null) {
            frontend_log.print(log.Level.err, "Failed to set session username.", .{});
            return -1;
        }
        _ = c.printf("Set session username to %s\n", &intf.ssn_params.username);
    } else if (eq(name, "pass") or eq(name, "password")) {
        c.ipmi_intf_session_set_password(@ptrCast(intf), value);
        if (intf.session == null) {
            frontend_log.print(log.Level.err, "Failed to set session password.", .{});
            return -1;
        }
        _ = c.printf("Set session password\n");
    } else if (eq(name, "authtype") or eq(name, "privlvl")) {
        const table = if (eq(name, "authtype")) c.ipmi_authtype_session_vals else c.ipmi_privlvl_vals;
        const parsed = c.str2val(value, table);
        if (parsed == 0xff) {
            frontend_log.print(log.Level.err, if (eq(name, "authtype")) "Invalid authtype: %s" else "Invalid privilege level: %s", .{value});
            return -1;
        }
        if (eq(name, "authtype")) {
            c.ipmi_intf_session_set_authtype(@ptrCast(intf), @intCast(parsed));
        } else c.ipmi_intf_session_set_privlvl(@ptrCast(intf), @intCast(parsed));
        if (intf.session == null) {
            frontend_log.print(log.Level.err, if (eq(name, "authtype")) "Failed to set session authtype." else "Failed to set session privilege level.", .{});
            return -1;
        }
        if (eq(name, "authtype")) {
            _ = c.printf("Set session authtype to %s\n", c.val2str(intf.ssn_params.authtype_set, table));
        } else _ = c.printf("Set session privilege level to %s\n", c.val2str(intf.ssn_params.privlvl, table));
    } else if (eq(name, "port")) {
        var port: c_int = 0;
        if (c.str2int(value, &port) != 0 or port > 65535) {
            frontend_log.print(log.Level.err, "Given port '%s' is invalid.", .{value});
            return -1;
        }
        c.ipmi_intf_session_set_port(@ptrCast(intf), port);
        if (intf.session == null) {
            frontend_log.print(log.Level.err, "Failed to set session port.", .{});
            return -1;
        }
        _ = c.printf("Set session port to %d\n", intf.ssn_params.port);
    } else if (eq(name, "localaddr") or eq(name, "targetaddr")) {
        var addr: u8 = 0;
        if (c.str2uchar(value, &addr) != 0) {
            frontend_log.print(log.Level.err, "Given %s '%s' is invalid.", .{ argv[0], value });
            return -1;
        }
        if (eq(name, "localaddr")) {
            intf.my_addr = addr;
            _ = c.printf("Set local IPMB address to 0x%02x\n", intf.my_addr);
        } else {
            intf.target_addr = addr;
            _ = c.printf("Set remote IPMB address to 0x%02x\n", intf.target_addr);
        }
    } else {
        setUsage();
        return -1;
    }
    return 0;
}

fn execMain(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    if (argc < 1) {
        frontend_log.print(log.Level.err, "Usage: exec <filename>", .{});
        return -1;
    }
    const fp = c.ipmi_open_file(argv[0], 0) orelse return -1;
    defer _ = c.fclose(fp);
    var buf: [2048]u8 = undefined;
    var rc: c_int = 0;
    while (c.fgets(&buf, buf.len, fp) != null) {
        const len = c.strlen(&buf);
        if (len == buf.len - 1 and buf[len - 1] != '\n') {
            var ch = c.fgetc(fp);
            if (ch != c.EOF and ch != '\n') {
                while (true) {
                    ch = c.fgetc(fp);
                    if (ch == c.EOF or ch == '\n') break;
                }
                frontend_log.print(log.Level.err, "exec: command line exceeds 2047 bytes", .{});
                rc = -1;
                continue;
            }
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const parsed = shell.parse(arena_state.allocator(), buf[0..len], true) catch |err| {
            frontend_log.print(log.Level.err, "Invalid command line: %s", .{@errorName(err).ptr});
            rc = -1;
            continue;
        };
        if (parsed.items.len == 0) continue;
        var args: [shell.max_args + 1][*c]u8 = @splat(null);
        for (parsed.items, 0..) |arg, i| args[i] = arg;
        const result = c.ipmi_cmd_run(@ptrCast(intf), args[0], @intCast(parsed.items.len - 1), &args[1]);
        if (result != 0) rc = result;
    }
    if (c.ferror(fp) != 0) {
        frontend_log.print(log.Level.err, "exec: unable to read file", .{});
        return -1;
    }
    return rc;
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(execMain), @TypeOf(c.ipmi_exec_main));
    abi.assertCallSignature(@TypeOf(setMain), @TypeOf(c.ipmi_set_main));
    abi.assertCallSignature(@TypeOf(echoMain), @TypeOf(c.ipmi_echo_main));
    @export(&execMain, .{ .name = "ipmi_exec_main" });
    @export(&setMain, .{ .name = "ipmi_set_main" });
    @export(&echoMain, .{ .name = "ipmi_echo_main" });
}
