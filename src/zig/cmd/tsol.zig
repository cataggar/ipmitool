//! Tyan SOL over the LAN interface: UDP receive, IPMI keystrokes and a raw
//! terminal. Selected with `-Dzig-modules=tsol`.
const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");

const port_default = c.IPMI_TSOL_DEF_PORT;
const cmd_start = c.IPMI_TSOL_CMD_START;
const cmd_stop = c.IPMI_TSOL_CMD_STOP;
const cmd_key = c.IPMI_TSOL_CMD_SENDKEY;

var keepalive_start: c.struct_timeval = std.mem.zeroes(c.struct_timeval);
var saved_tio: c.struct_termios = std.mem.zeroes(c.struct_termios);
var saved_winsize: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
var in_raw_mode = false;
var altterm = false;
var in_escape = false;
var last_was_cr = true;
var key_sequence: u8 = 0;

fn command(intf: *Intf, recvip: [*:0]u8, port: c_int, cmd: u8) c_int {
    var ip1: c_uint = 0;
    var ip2: c_uint = 0;
    var ip3: c_uint = 0;
    var ip4: c_uint = 0;
    if (c.sscanf(recvip, "%d.%d.%d.%d", &ip1, &ip2, &ip3, &ip4) != 4) {
        c.lprintf(log.Level.err, "Invalid IP address: %s", recvip);
        return -1;
    }
    const port_bits: u32 = @bitCast(port);
    var data = [6]u8{
        @truncate(ip1),            @truncate(ip2),       @truncate(ip3), @truncate(ip4),
        @truncate(port_bits >> 8), @truncate(port_bits),
    };
    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.tsol;
    req.msg.cmd = cmd;
    req.msg.data_len = data.len;
    req.msg.data = &data;
    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(log.Level.err, "Unable to perform TSOL command");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Unable to perform TSOL command: %s", c.val2str(rsp.ccode, c.completion_code_vals));
        return -1;
    }
    return 0;
}

fn sendKeystroke(intf: *Intf, buff: []const u8) c_int {
    var data: [16]u8 = @splat(0);
    data[0] = @intCast(buff.len + 1);
    @memcpy(data[1..][0..buff.len], buff);
    data[buff.len + 1] = key_sequence;
    key_sequence +%= 1;
    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.tsol;
    req.msg.cmd = cmd_key;
    req.msg.data_len = @intCast(buff.len + 2);
    req.msg.data = &data;
    const rsp = intf.sendrecv.?(intf, &req);
    if (c.verbose != 0) {
        const response = rsp orelse {
            c.lprintf(log.Level.err, "Unable to send keystroke");
            return -1;
        };
        if (response.ccode != 0) {
            c.lprintf(log.Level.err, "Unable to send keystroke: %s", c.val2str(response.ccode, c.completion_code_vals));
            return -1;
        }
    }
    return @intCast(buff.len);
}

fn keepalive(intf: *Intf) void {
    var end: c.struct_timeval = undefined;
    _ = c.gettimeofday(&end, null);
    if (end.tv_sec - keepalive_start.tv_sec <= 30) return;
    _ = intf.keepalive.?(intf);
    _ = c.gettimeofday(&keepalive_start, null);
}

fn printEscapes(intf: *Intf) void {
    const esc: c_int = intf.ssn_params.sol_escape_char;
    c.lprintf(log.Level.notice, "       %c.  - terminate connection\n" ++
        "       %c^Z - suspend ipmitool\n" ++
        "       %c^X - suspend ipmitool, but don't restore tty on restart\n" ++
        "       %c?  - this message\n" ++
        "       %c%c  - send the escape character by typing it twice\n" ++
        "       (Note that escapes are only recognized immediately after newline.)", esc, esc, esc, esc, esc, esc);
}

fn leaveRawMode() void {
    if (!in_raw_mode) return;
    if (c.tcsetattr(0, c.TCSADRAIN, &saved_tio) == -1) {
        c.lperror(log.Level.err, "tcsetattr(stdin)");
    } else if (c.tcsetattr(1, c.TCSADRAIN, &saved_tio) == -1) {
        c.lperror(log.Level.err, "tcsetattr(stdout)");
    } else {
        in_raw_mode = false;
    }
}

fn enterRawMode() void {
    if (c.tcgetattr(1, &saved_tio) < 0) {
        c.lperror(log.Level.err, "tcgetattr failed");
        return;
    }
    var tio = saved_tio;
    if (altterm) {
        tio.c_iflag &= c.ISTRIP | c.IGNBRK;
        tio.c_cflag &= ~@as(@TypeOf(tio.c_cflag), c.CSIZE | c.PARENB | c.IXON | c.IXOFF | c.IXANY);
        tio.c_cflag |= (c.CS8 | c.CREAD) | (c.IXON | c.IXOFF | c.IXANY);
        tio.c_lflag &= 0;
    } else {
        tio.c_iflag |= c.IGNPAR;
        tio.c_iflag &= ~@as(@TypeOf(tio.c_iflag), c.ISTRIP | c.INLCR | c.IGNCR | c.ICRNL | c.IXON | c.IXANY | c.IXOFF);
        tio.c_lflag &= ~@as(@TypeOf(tio.c_lflag), c.ISIG | c.ICANON | c.ECHO | c.ECHOE | c.ECHOK | c.ECHONL | c.IEXTEN);
        tio.c_oflag &= ~@as(@TypeOf(tio.c_oflag), c.OPOST);
    }
    tio.c_cc[c.VMIN] = 1;
    tio.c_cc[c.VTIME] = 0;
    if (c.tcsetattr(0, c.TCSADRAIN, &tio) < 0) {
        c.lperror(log.Level.err, "tcsetattr(stdin)");
    } else if (c.tcsetattr(1, c.TCSADRAIN, &tio) < 0) {
        c.lperror(log.Level.err, "tcsetattr(stdout)");
    } else {
        in_raw_mode = true;
    }
}

fn suspendSelf(restore_tty: bool) void {
    leaveRawMode();
    _ = c.kill(c.getpid(), c.SIGTSTP);
    if (restore_tty) enterRawMode();
}

fn inbufActions(intf: *Intf, buff: []u8) c_int {
    var len = buff.len;
    var i: usize = 0;
    while (i < len) {
        if (!in_escape and last_was_cr and buff[i] == intf.ssn_params.sol_escape_char) {
            in_escape = true;
            // Keep the original's shift from the start of this read rather
            // than from `i`: it affects the bytes sent after a mid-read escape.
            std.mem.copyForwards(u8, buff[0 .. len - i - 1], buff[1 .. len - i]);
            len -= 1;
            continue;
        }
        if (in_escape) {
            if (buff[i] == intf.ssn_params.sol_escape_char) {
                in_escape = false;
                i += 1;
                continue;
            }
            switch (buff[i]) {
                '.' => {
                    _ = c.printf("%c. [terminated ipmitool]\n", @as(c_int, intf.ssn_params.sol_escape_char));
                    return -1;
                },
                'Z' - 64 => {
                    _ = c.printf("%c^Z [suspend ipmitool]\n", @as(c_int, intf.ssn_params.sol_escape_char));
                    suspendSelf(true);
                },
                'X' - 64 => {
                    _ = c.printf("%c^X [suspend ipmitool]\n", @as(c_int, intf.ssn_params.sol_escape_char));
                    suspendSelf(false);
                },
                '?' => {
                    _ = c.printf("%c? [ipmitool help]\n", @as(c_int, intf.ssn_params.sol_escape_char));
                    printEscapes(intf);
                },
                else => {},
            }
            std.mem.copyForwards(u8, buff[0 .. len - i - 1], buff[1 .. len - i]);
            len -= 1;
            in_escape = false;
            continue;
        }
        last_was_cr = buff[i] == '\r' or buff[i] == '\n';
        i += 1;
    }
    return @intCast(len);
}

fn terminalCleanup() void {
    if (saved_winsize.ws_row > 0 and saved_winsize.ws_col > 0)
        _ = c.ioctl(1, c.TIOCSWINSZ, &saved_winsize);
    leaveRawMode();
    const err = c.__errno_location().*;
    if (err != 0) c.lprintf(log.Level.err, "Exiting due to error %d -> %s", err, c.strerror(err));
}

fn setTerminalSize(rows: c_int, cols: c_int) void {
    if (rows <= 0 or cols <= 0) return;
    _ = c.ioctl(1, c.TIOCGWINSZ, &saved_winsize);
    var size = std.mem.zeroes(c.struct_winsize);
    size.ws_row = @truncate(@as(u32, @bitCast(rows)));
    size.ws_col = @truncate(@as(u32, @bitCast(cols)));
    _ = c.ioctl(1, c.TIOCSWINSZ, &size);
}

fn usage() void {
    var size: c.struct_winsize = undefined;
    c.lprintf(log.Level.notice, "Usage: tsol [recvip] [port=NUM] [ro|rw] [rows=NUM] [cols=NUM] [altterm]");
    c.lprintf(log.Level.notice, "       recvip       Receiver IP Address             [default=local]");
    c.lprintf(log.Level.notice, "       port=NUM     Receiver UDP Port               [default=%d]", @as(c_int, port_default));
    c.lprintf(log.Level.notice, "       ro|rw        Set Read-Only or Read-Write     [default=rw]");
    _ = c.ioctl(1, c.TIOCGWINSZ, &size);
    c.lprintf(log.Level.notice, "       rows=NUM     Set terminal rows               [default=%d]", @as(c_int, size.ws_row));
    c.lprintf(log.Level.notice, "       cols=NUM     Set terminal columns            [default=%d]", @as(c_int, size.ws_col));
    c.lprintf(log.Level.notice, "       altterm      Alternate terminal setup        [default=off]");
}

fn main(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    if (!std.mem.eql(u8, std.mem.sliceTo(&intf.name, 0), "lan")) {
        c.lprintf(log.Level.err, "Error: Tyan SOL is only available over lan interface");
        return -1;
    }
    var recvip: ?[*:0]u8 = null;
    var read_only = false;
    var rows: c_int = 0;
    var cols: c_int = 0;
    var port: c_int = port_default;
    for (argv[0..@intCast(argc)]) |arg| {
        var ip1: c_int = undefined;
        var ip2: c_int = undefined;
        var ip3: c_int = undefined;
        var ip4: c_int = undefined;
        if (c.sscanf(arg, "%d.%d.%d.%d", &ip1, &ip2, &ip3, &ip4) == 4) {
            recvip = @constCast(arg);
        } else if (c.sscanf(arg, "port=%d", &ip1) == 1) {
            port = ip1;
        } else if (c.sscanf(arg, "rows=%d", &ip1) == 1) {
            rows = ip1;
        } else if (c.sscanf(arg, "cols=%d", &ip1) == 1) {
            cols = ip1;
        } else if (std.mem.eql(u8, std.mem.span(arg), "ro")) {
            read_only = true;
        } else if (std.mem.eql(u8, std.mem.span(arg), "rw")) {
            read_only = false;
        } else if (std.mem.eql(u8, std.mem.span(arg), "altterm")) {
            altterm = true;
        } else if (std.mem.eql(u8, std.mem.span(arg), "help")) {
            usage();
            return 0;
        } else {
            c.lprintf(log.Level.err, "Invalid tsol command: '%s'\n", arg);
            usage();
            return -1;
        }
    }

    var sin = std.mem.zeroes(c.struct_sockaddr_in);
    sin.sin_family = c.AF_INET;
    sin.sin_port = c.htons(@truncate(@as(u32, @bitCast(port))));
    const session = intf.session.?;
    const sa_in: *c.struct_sockaddr_in = @ptrCast(@alignCast(&session.addr));
    const hostname = intf.ssn_params.hostname.?;
    if (c.inet_pton(c.AF_INET, hostname, &sa_in.sin_addr) <= 0) {
        const host = c.gethostbyname(hostname);
        if (host == null) {
            c.lprintf(log.Level.err, "Address lookup for %s failed", hostname);
            return -1;
        }
        if (host.*.h_addrtype != c.AF_INET) {
            c.lprintf(log.Level.err, "Address lookup for %s failed. Got %s, expected IPv4 address.", hostname, @as([*:0]const u8, if (host.*.h_addrtype == c.AF_INET6) "IPv6" else "Unknown"));
            return -1;
        }
        sa_in.sin_family = @intCast(host.*.h_addrtype);
        const n: usize = @intCast(host.*.h_length);
        @memcpy(std.mem.asBytes(&sa_in.sin_addr)[0..n], @as([*]const u8, @ptrCast(host.*.h_addr_list[0]))[0..n]);
    }

    const fd_socket = c.socket(c.PF_INET, c.SOCK_DGRAM, c.IPPROTO_UDP);
    if (fd_socket < 0) {
        c.lprintf(log.Level.err, "Can't open port %d", port);
        return -1;
    }
    defer _ = c.close(fd_socket);
    if (c.bind(fd_socket, @ptrCast(&sin), @sizeOf(c.struct_sockaddr_in)) == -1) {
        c.lprintf(log.Level.err, "Failed to bind socket.");
        return -1;
    }
    if (recvip == null) {
        if (intf.open.?(intf) < 0) return -1;
        var myaddr: c.struct_sockaddr_in = undefined;
        var mylen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(intf.fd, @ptrCast(&myaddr), &mylen) < 0) {
            c.lperror(log.Level.err, "getsockname failed");
            return -1;
        }
        const addr = c.inet_ntoa(myaddr.sin_addr);
        if (addr == null) {
            c.lprintf(log.Level.err, "Unable to find local IP address");
            return -1;
        }
        recvip = @ptrCast(addr);
    }
    const receiver = recvip.?;
    _ = c.printf("[Starting %sSOL with receiving address %s:%d]\n", @as([*:0]const u8, if (read_only) "Read-only " else ""), receiver, port);
    setTerminalSize(rows, cols);
    enterRawMode();
    const started = command(intf, receiver, port, cmd_start);
    if (started < 0) {
        c.lprintf(log.Level.err, "Error starting SOL");
        terminalCleanup();
        return -1;
    }
    _ = c.printf("[SOL Session operational.  Use %c? for help]\n", @as(c_int, intf.ssn_params.sol_escape_char));
    _ = c.gettimeofday(&keepalive_start, null);

    var wait = [3]c.struct_pollfd{
        .{ .fd = fd_socket, .events = c.POLLIN, .revents = 0 },
        .{ .fd = 0, .events = c.POLLIN, .revents = 0 },
        .{ .fd = -1, .events = 0, .revents = 0 },
    };
    var data_wait = [3]c.struct_pollfd{
        .{ .fd = fd_socket, .events = c.POLLIN | c.POLLOUT, .revents = 0 },
        .{ .fd = 0, .events = c.POLLIN, .revents = 0 },
        .{ .fd = 1, .events = c.POLLOUT, .revents = 0 },
    };
    var fds: *[3]c.struct_pollfd = &wait;
    var in_buff: [ipmi.buf_size]u8 = undefined;
    var out_buff: [ipmi.buf_size * 8]u8 = undefined;
    var buff: [ipmi.buf_size + 4]u8 = undefined;
    var in_fill: usize = 0;
    var out_fill: usize = 0;
    while (true) {
        const result = c.poll(@ptrCast(fds), 3, 15 * 1000);
        if (result < 0) {
            _ = command(intf, receiver, port, cmd_stop);
            terminalCleanup();
            return 0;
        }
        keepalive(intf);
        if (fds[0].revents & c.POLLIN != 0 and out_fill < out_buff.len) {
            var sin_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
            const size = @min(buff.len, out_buff.len - out_fill + 4);
            const got = c.recvfrom(fd_socket, &buff, size, 0, @ptrCast(&sin), &sin_len);
            if (got > 4) {
                const n: usize = @intCast(got - 4);
                @memcpy(out_buff[out_fill..][0..n], buff[4..][0..n]);
                out_fill += n;
            }
        }
        if (fds[1].revents & c.POLLIN != 0 and in_fill < in_buff.len) {
            const got = c.read(0, @ptrCast(&in_buff[in_fill]), in_buff.len - in_fill);
            if (got > 0) {
                var bytes = inbufActions(intf, in_buff[in_fill..][0..@intCast(got)]);
                if (bytes < 0) {
                    const stopped = command(intf, receiver, port, cmd_stop);
                    terminalCleanup();
                    return stopped;
                }
                if (read_only) bytes = 0;
                in_fill += @intCast(bytes);
            }
        }
        if (fds[2].revents & c.POLLOUT != 0 and out_fill > 0) {
            const written = c.write(1, &out_buff, out_fill);
            if (written > 0) {
                const n: usize = @intCast(written);
                out_fill -= n;
                std.mem.copyForwards(u8, out_buff[0..out_fill], out_buff[n..][0..out_fill]);
            }
        }
        if (fds[0].revents & c.POLLOUT != 0 and in_fill > 0) {
            const sent = sendKeystroke(intf, in_buff[0..@min(in_fill, 14)]);
            if (sent > 0) {
                _ = c.gettimeofday(&keepalive_start, null);
                const n: usize = @intCast(sent);
                in_fill -= n;
                std.mem.copyForwards(u8, in_buff[0..in_fill], in_buff[n..][0..in_fill]);
            }
        }
        fds = if (in_fill > 0 or out_fill > 0) &data_wait else &wait;
    }
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(main), @TypeOf(c.ipmi_tsol_main));
    @export(&main, .{ .name = "ipmi_tsol_main", .linkage = .strong });
}
