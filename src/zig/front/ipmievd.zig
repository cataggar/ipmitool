//! The ipmievd frontend. The C frontend remains the default oracle; select
//! this executable with `zig build -Dzig-modules=evd`.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("ipmi_c");
const headers = @import("ipmi_zig");
const abi = headers.abi;
const Intf = headers.intf.ipmi_intf.Intf;
const Cmd = headers.intf.ipmi_intf.Cmd;
const ipmi = headers.core.ipmi;
const open = headers.intf.open;
const log = headers.util.log;
const frontend_log = headers.frontend_log;
const open_enabled = @hasDecl(c, "IPMI_INTF_OPEN");

const Event = extern struct {
    record_id: u16 align(1) = 0,
    record_type: u8 = 0,
    sel_type: extern union {
        standard_type: extern struct {
            timestamp: u32 = 0,
            gen_id: u16 = 0,
            evm_rev: u8 = 0,
            sensor_type: u8 = 0,
            sensor_num: u8 = 0,
            type_dir: packed struct(u8) { kind: u7 = 0, direction: u1 = 0 } = .{},
            event_data: [3]u8 = .{ 0, 0, 0 },
        },
        bytes: [16]u8,
    } align(1) = .{ .bytes = @splat(0) },
};

const EventIntf = extern struct {
    name: [16]u8,
    desc: [128]u8,
    prefix: [72]u8,
    setup: ?*const fn (*EventIntf) callconv(.c) c_int,
    wait: ?*const fn (*EventIntf) callconv(.c) c_int,
    read: ?*const fn (*EventIntf) callconv(.c) c_int,
    check: ?*const fn (*EventIntf) callconv(.c) c_int,
    log_event: ?*const fn (*EventIntf, *Event) callconv(.c) void,
    intf: ?*Intf = null,
};

const SdrList = extern struct {
    id: u16 align(1),
    version: u8,
    type: u8,
    length: u8,
    raw: ?[*]u8 align(1),
    next: ?*SdrList align(1),
    record: ?[*]const u8 align(1),
};

comptime {
    abi.assertOpaqueLayout(Event, .{
        .size = c.ABI_SIZEOF_sel_event_record,
        .alignment = c.ABI_ALIGNOF_sel_event_record,
        .fields = &.{
            .{ .name = "record_id", .offset = c.ABI_OFFSETOF_sel_event_record__record_id },
            .{ .name = "record_type", .offset = c.ABI_OFFSETOF_sel_event_record__record_type },
            .{ .name = "sel_type", .offset = c.ABI_OFFSETOF_sel_event_record__sel_type },
        },
    });
    abi.assertOpaqueLayout(SdrList, .{
        .size = c.ABI_SIZEOF_sdr_record_list,
        .alignment = c.ABI_ALIGNOF_sdr_record_list,
        .fields = &.{
            .{ .name = "id", .offset = c.ABI_OFFSETOF_sdr_record_list__id },
            .{ .name = "version", .offset = c.ABI_OFFSETOF_sdr_record_list__version },
            .{ .name = "type", .offset = c.ABI_OFFSETOF_sdr_record_list__type },
            .{ .name = "length", .offset = c.ABI_OFFSETOF_sdr_record_list__length },
            .{ .name = "raw", .offset = c.ABI_OFFSETOF_sdr_record_list__raw },
            .{ .name = "next", .offset = c.ABI_OFFSETOF_sdr_record_list__next },
            .{ .name = "record", .offset = c.ABI_OFFSETOF_sdr_record_list__record },
        },
    });
}

pub export var verbose: c_int = 0;
pub export var csv_output: c_int = 0;
pub export var selwatch_count: u16 = 0;
pub export var selwatch_lastid: u16 = 0;
pub export var selwatch_pctused: c_int = 0;
pub export var selwatch_overflow: c_int = 0;
pub export var selwatch_timeout: c_int = 10;

var pidfile: [64]u8 = @splat(0);
var pid_owned = false;
var stop_signal: c.sig_atomic_t = 0;

const Io = struct {
    ioctl: *const fn (c_int, c_ulong, ?*anyopaque) c_int = realIoctl,
    poll: *const fn ([*c]c.struct_pollfd, c.nfds_t, c_int) c_int = realPoll,
    sleep: *const fn (c_uint) c_uint = realSleep,
    daemonize: *const fn (*Intf) void = realDaemonize,
    cache: *const fn (*Intf) void = realCache,
    install_signals: *const fn () void = realSignals,
    pid_exists: *const fn ([*:0]const u8) bool = realPidExists,
    pid_write: *const fn ([*:0]const u8) bool = realPidWrite,
    pid_remove: *const fn ([*:0]const u8) void = realPidRemove,
};
var io: Io = .{};

fn realIoctl(fd: c_int, request: c_ulong, arg: ?*anyopaque) c_int {
    return c.ioctl(fd, open.libcRequest(request), arg);
}
fn realPoll(fds: [*c]c.struct_pollfd, count: c.nfds_t, timeout: c_int) c_int {
    return c.poll(fds, count, timeout);
}
fn realSleep(seconds: c_uint) c_uint {
    return c.sleep(seconds);
}
fn realDaemonize(intf: *Intf) void {
    c.ipmi_start_daemon(@ptrCast(intf));
}
fn realCache(intf: *Intf) void {
    _ = c.ipmi_sdr_list_cache(@ptrCast(intf));
}
fn onSignal(_: c_int) callconv(.c) void {
    @as(*volatile c.sig_atomic_t, @ptrCast(&stop_signal)).* = 1;
}
fn stopped() bool {
    return @as(*volatile c.sig_atomic_t, @ptrCast(&stop_signal)).* != 0;
}
fn realSignals() void {
    // sigaction, unlike signal(3), does not add SA_RESTART: the blocking poll
    // must return on SIGINT/SIGQUIT/SIGTERM so that cleanup runs in normal code.
    var action = std.mem.zeroes(c.struct_sigaction);
    if (comptime builtin.target.abi == .musl) {
        action.__sa_handler.sa_handler = onSignal;
    } else {
        action.__sigaction_handler.sa_handler = onSignal;
    }
    _ = c.sigemptyset(&action.sa_mask);
    _ = c.sigaction(c.SIGINT, &action, null);
    _ = c.sigaction(c.SIGQUIT, &action, null);
    _ = c.sigaction(c.SIGTERM, &action, null);
}
fn realPidExists(path: [*:0]const u8) bool {
    if (comptime builtin.target.abi == .musl) {
        var st: std.os.linux.Statx = undefined;
        return std.os.linux.errno(std.os.linux.statx(
            std.os.linux.AT.FDCWD,
            path,
            std.os.linux.AT.SYMLINK_NOFOLLOW,
            .BASIC_STATS,
            &st,
        )) == .SUCCESS;
    } else {
        var st: c.struct_stat = undefined;
        return c.lstat(path, &st) == 0;
    }
}
fn realPidWrite(path: [*:0]const u8) bool {
    const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c.mode_t, 0o644));
    if (fd < 0) return false;
    const fp = c.fdopen(fd, "w");
    if (fp == null) {
        _ = c.close(fd);
        _ = c.unlink(path);
        return false;
    }
    const written = c.fprintf(fp, "%d\n", c.getpid()) >= 0;
    const closed = c.fclose(fp) == 0;
    if (!written or !closed) {
        _ = c.unlink(path);
        return false;
    }
    return true;
}
fn realPidRemove(path: [*:0]const u8) void {
    _ = c.unlink(path);
}
fn pidPath() [*:0]const u8 {
    return @ptrCast(&pidfile);
}
fn cleanup() void {
    if (pid_owned) {
        io.pid_remove(pidPath());
        pid_owned = false;
    }
}

fn useName(e: *EventIntf) [*:0]const u8 {
    return @ptrCast(&e.name);
}
fn prefix(e: *EventIntf) [*:0]const u8 {
    return @ptrCast(&e.prefix);
}
fn cIntf(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}
fn ccode(code: u8) [*c]const u8 {
    return c.val2str(code, c.completion_code_vals);
}
fn putEvent(e: *EventIntf, evt: *Event) void {
    if (e.log_event) |callback| callback(e, evt);
}

fn logEvent(e: *EventIntf, evt: *Event) callconv(.c) void {
    const intf = e.intf.?;
    if (evt.record_type == 0xf0) {
        frontend_log.print(log.Level.alert, "%sLinux kernel panic: %.11s", .{ prefix(e), @as([*c]u8, @ptrCast(evt)) + 5 });
        return;
    }
    if (evt.record_type >= 0xc0) {
        frontend_log.print(log.Level.notice, "%sIPMI Event OEM Record %02x", .{ prefix(e), @as(c_int, evt.record_type) });
        return;
    }

    const standard = &evt.sel_type.standard_type;
    const sensor_type = c.ipmi_get_sensor_type(cIntf(intf), standard.sensor_type);
    var desc: [*c]u8 = null;
    c.ipmi_get_event_desc(cIntf(intf), @ptrCast(evt), &desc);
    defer if (desc != null) c.free(desc);
    const sdr_ptr = c.ipmi_sdr_find_sdr_bynumtype(
        cIntf(intf),
        standard.gen_id,
        standard.sensor_num,
        standard.sensor_type,
    );
    if (sdr_ptr == null) {
        if (desc != null) {
            frontend_log.print(log.Level.notice, "%s%s sensor - %s", .{ prefix(e), sensor_type, desc });
        } else {
            frontend_log.print(log.Level.notice, "%s%s sensor %02x", .{ prefix(e), sensor_type, @as(c_int, standard.sensor_num) });
        }
        return;
    }
    const sdr: *SdrList = @ptrCast(sdr_ptr);
    const raw = sdr.record orelse return;
    const description: [*c]const u8 = if (desc != null) desc else "";
    const direction: [*:0]const u8 = if (standard.type_dir.direction == 1) "Deasserted" else "Asserted";
    switch (sdr.type) {
        c.SDR_RECORD_TYPE_FULL_SENSOR => {
            const id_string: [*:0]const u8 = @ptrCast(raw + c.ABI_OFFSETOF_sdr_full__id_string);
            const event_type = standard.type_dir.kind;
            if (event_type == 1) {
                const full: *c.struct_sdr_record_full_sensor = @ptrCast(@alignCast(@constCast(raw)));
                const data = standard.event_data;
                const reading: f64 = if ((data[0] >> 6) & 3 == 1)
                    c.sdr_convert_sensor_reading(full, data[1])
                else
                    0;
                const threshold: f64 = if ((data[0] >> 4) & 3 == 1)
                    c.sdr_convert_sensor_reading(full, data[2])
                else
                    0;
                const common = raw;
                const unit = common[c.ABI_OFFSETOF_sdr_common__unit];
                frontend_log.print(
                    log.Level.notice,
                    "%s%s sensor %s %s %s (Reading %.*f %s Threshold %.*f %s)",
                    .{
                        prefix(e),
                        sensor_type,
                        id_string,
                        description,
                        direction,
                        @as(c_int, if (reading == @trunc(reading)) 0 else 2),
                        reading,
                        @as([*:0]const u8, if (data[0] & 0xf & 1 == 1) ">" else "<"),
                        @as(c_int, if (threshold == @trunc(threshold)) 0 else 2),
                        threshold,
                        c.ipmi_sdr_get_unit_string(
                            unit & 1 != 0,
                            (unit >> 1) & 3,
                            common[c.ABI_OFFSETOF_sdr_common__unit__type__base],
                            common[c.ABI_OFFSETOF_sdr_common__unit__type__modifier],
                        ),
                    },
                );
            } else if ((event_type >= 2 and event_type <= 12) or
                event_type == 0x6f or (event_type >= 0x70 and event_type <= 0x7f))
            {
                frontend_log.print(log.Level.notice, "%s%s sensor %s %s %s", .{ prefix(e), sensor_type, id_string, description, direction });
            }
        },
        c.SDR_RECORD_TYPE_COMPACT_SENSOR => {
            const id_string: [*:0]const u8 = @ptrCast(raw + c.ABI_OFFSETOF_sdr_compact__id_string);
            frontend_log.print(log.Level.notice, "%s%s sensor %s - %s %s", .{ prefix(e), sensor_type, id_string, description, direction });
        },
        else => frontend_log.print(log.Level.notice, "%s%s sensor (0x%02x) - %s", .{ prefix(e), sensor_type, @as(c_int, standard.sensor_num), description }),
    }
}

const SelData = struct { entries: u16, pctused: c_int, overflow: c_int };
fn selInfo(intf: *Intf) ?SelData {
    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.IPMI_CMD_GET_SEL_INFO;
    const rsp = intf.sendrecv.?(intf, &req) orelse {
        frontend_log.print(log.Level.err, "Get SEL Info command failed", .{});
        return null;
    };
    if (rsp.ccode != 0) {
        frontend_log.print(log.Level.err, "Get SEL Info command failed: %s", .{ccode(rsp.ccode)});
        return null;
    }
    if (rsp.data_len < 14) {
        frontend_log.print(log.Level.err, "Get SEL Info response is too short", .{});
        return null;
    }
    const entries = std.mem.readInt(u16, rsp.data[1..3], .little);
    const free_space = std.mem.readInt(u16, rsp.data[3..5], .little);
    const bytes_used: u32 = @as(u32, entries) * 16;
    const pct: c_int = if (bytes_used == 0) 0 else @intFromFloat(@as(f64, 100) * @as(f64, @floatFromInt(bytes_used)) /
        @as(f64, @floatFromInt(bytes_used + free_space)));
    frontend_log.print(log.Level.debug, "SEL count is %d", .{@as(c_int, entries)});
    frontend_log.print(log.Level.debug, "SEL freespace is %d", .{@as(c_int, free_space)});
    return .{
        .entries = entries,
        .pctused = pct,
        .overflow = if (rsp.data[13] & 0x80 != 0) 1 else 0,
    };
}

fn selEntry(intf: *Intf, id: u16, evt: *Event) ?u16 {
    var request_data: [6]u8 = .{ 0, 0, @truncate(id), @truncate(id >> 8), 0, 0xff };
    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.IPMI_CMD_GET_SEL_ENTRY;
    req.msg.data = &request_data;
    req.msg.data_len = request_data.len;
    const rsp = intf.sendrecv.?(intf, &req) orelse {
        frontend_log.print(log.Level.err, "Get SEL Entry %x command failed", .{@as(c_int, id)});
        return null;
    };
    if (rsp.ccode != 0 or rsp.data_len < 18) {
        frontend_log.print(log.Level.err, "Get SEL Entry %x failed or malformed", .{@as(c_int, id)});
        return null;
    }
    const next = std.mem.readInt(u16, rsp.data[0..2], .little);
    @memcpy(std.mem.asBytes(evt)[0..16], rsp.data[2..18]);
    return next;
}

fn lastId(intf: *Intf) ?u16 {
    if (selwatch_count == 0) return 0;
    var next: u16 = 0;
    var last: u16 = 0;
    var evt: Event = .{};
    while (next != 0xffff and !stopped()) {
        const requested = next;
        next = selEntry(intf, requested, &evt) orelse return null;
        if (next == 0) next = selEntry(intf, requested, &evt) orelse return null;
        if (next == 0) break;
        last = evt.record_id;
        if (next == requested) break;
    }
    return last;
}

fn selSetup(e: *EventIntf) callconv(.c) c_int {
    const data = selInfo(e.intf.?) orelse {
        frontend_log.print(log.Level.err, "Unable to retrieve SEL data", .{});
        return -1;
    };
    selwatch_count = data.entries;
    selwatch_pctused = data.pctused;
    selwatch_overflow = data.overflow;
    selwatch_lastid = lastId(e.intf.?) orelse return -1;
    if (selwatch_pctused >= 80)
        frontend_log.print(log.Level.warning, "SEL buffer used at %d%%, please consider clearing the SEL buffer", .{selwatch_pctused});
    if (selwatch_overflow != 0)
        frontend_log.print(log.Level.alert, "SEL buffer overflow, no SEL message can be logged until the SEL buffer is cleared", .{});
    return 0;
}
fn selCheck(e: *EventIntf) callconv(.c) c_int {
    const old_count = selwatch_count;
    const old_pct = selwatch_pctused;
    const old_overflow = selwatch_overflow;
    const data = selInfo(e.intf.?) orelse return -1;
    selwatch_count = data.entries;
    selwatch_pctused = data.pctused;
    selwatch_overflow = data.overflow;
    if (old_overflow != 0 and selwatch_overflow == 0)
        frontend_log.print(log.Level.notice, "SEL overflow is cleared", .{})
    else if (old_overflow == 0 and selwatch_overflow != 0)
        frontend_log.print(log.Level.alert, "SEL buffer overflow, no new SEL message will be logged until the SEL buffer is cleared", .{});
    if (selwatch_pctused >= 80 and selwatch_pctused > old_pct)
        frontend_log.print(log.Level.warning, "SEL buffer is %d%% full, please consider clearing the SEL buffer", .{selwatch_pctused});
    if (selwatch_count == 0)
        selwatch_lastid = 0
    else if (selwatch_count < old_count)
        selwatch_lastid = lastId(e.intf.?) orelse return -1;
    return @intFromBool(selwatch_count > old_count);
}
fn selRead(e: *EventIntf) callconv(.c) c_int {
    if (selwatch_count == 0) return -1;
    var next = selwatch_lastid;
    var last = selwatch_lastid;
    var evt: Event = .{};
    while (next != 0xffff and !stopped()) {
        const requested = next;
        next = selEntry(e.intf.?, requested, &evt) orelse {
            selwatch_lastid = last;
            return -1;
        };
        if (next == 0) next = selEntry(e.intf.?, requested, &evt) orelse {
            selwatch_lastid = last;
            return -1;
        };
        if (next == 0) break;
        if (evt.record_id != selwatch_lastid or requested == 0) putEvent(e, &evt);
        last = evt.record_id;
        if (next == requested) break;
    }
    selwatch_lastid = last;
    return 0;
}
fn selWait(e: *EventIntf) callconv(.c) c_int {
    while (!stopped()) {
        const changed = e.check.?(e);
        if (changed < 0) return -1;
        if (changed > 0 and e.read.?(e) < 0) return -1;
        if (!stopped()) _ = io.sleep(@intCast(selwatch_timeout));
    }
    return 0;
}

fn openEnable(intf: *Intf) c_int {
    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app;
    req.msg.cmd = 0x2f;
    const first = intf.sendrecv.?(intf, &req) orelse return -1;
    if (first.ccode != 0 or first.data_len < 1) {
        frontend_log.print(log.Level.err, "Get BMC Global Enables failed or malformed", .{});
        return -1;
    }
    var enables: u8 = first.data[0] | 0x04;
    req.msg.cmd = 0x2e;
    req.msg.data = @ptrCast(&enables);
    req.msg.data_len = 1;
    const second = intf.sendrecv.?(intf, &req) orelse return -1;
    if (second.ccode != 0) {
        frontend_log.print(log.Level.err, "Set BMC Global Enables command failed: %s", .{ccode(second.ccode)});
        return -1;
    }
    return 0;
}
fn openSetup(e: *EventIntf) callconv(.c) c_int {
    if (openEnable(e.intf.?) < 0) return -1;
    var enabled: c_int = 1;
    if (io.ioctl(e.intf.?.fd, open.ipmictl_set_gets_events_cmd, &enabled) != 0) {
        frontend_log.perror(log.Level.err, "Could not enable event receiver", .{});
        return -1;
    }
    return 0;
}
fn openRead(e: *EventIntf) callconv(.c) c_int {
    var address: open.Addr = undefined;
    var data: [80]u8 = undefined;
    var recv: open.Recv = std.mem.zeroes(open.Recv);
    recv.addr = @ptrCast(&address);
    recv.addr_len = @sizeOf(open.Addr);
    recv.msg.data = &data;
    recv.msg.data_len = data.len;
    if (io.ioctl(e.intf.?.fd, open.ipmictl_receive_msg_trunc, &recv) < 0) {
        const err = std.c._errno().*;
        if (err == c.EINTR) return 0;
        if (err != c.EMSGSIZE) {
            frontend_log.perror(log.Level.err, "Unable to receive IPMI message", .{});
            return -1;
        }
        recv.msg.data_len = data.len;
    }
    if (recv.recv_type != c.IPMI_ASYNC_EVENT_RECV_TYPE or
        recv.msg.data == null or recv.msg.data_len < 16)
    {
        frontend_log.print(log.Level.err, "Invalid or truncated OpenIPMI event", .{});
        return -1;
    }
    var evt: Event = .{};
    @memcpy(std.mem.asBytes(&evt)[0..16], recv.msg.data.?[0..16]);
    putEvent(e, &evt);
    return 0;
}
fn openWait(e: *EventIntf) callconv(.c) c_int {
    while (!stopped()) {
        var pfd = c.struct_pollfd{ .fd = e.intf.?.fd, .events = c.POLLIN, .revents = 0 };
        const result = io.poll(&pfd, 1, -1);
        if (result < 0) {
            if (stopped() and std.c._errno().* == c.EINTR) break;
            frontend_log.perror(log.Level.crit, "Unable to read from IPMI device", .{});
            return -1;
        }
        if (result > 0) {
            if (pfd.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return -1;
            if (pfd.revents & c.POLLIN != 0 and e.read.?(e) < 0) return -1;
        }
    }
    return 0;
}

var open_event = EventIntf{
    .name = padded(16, "open"),
    .desc = padded(128, "OpenIPMI asynchronous notification of events"),
    .prefix = @splat(0),
    .setup = openSetup,
    .wait = openWait,
    .read = openRead,
    .check = null,
    .log_event = logEvent,
};
var sel_event = EventIntf{
    .name = padded(16, "sel"),
    .desc = padded(128, "Poll SEL for notification of events"),
    .prefix = @splat(0),
    .setup = selSetup,
    .wait = selWait,
    .read = selRead,
    .check = selCheck,
    .log_event = logEvent,
};
fn padded(comptime length: usize, comptime text: []const u8) [length]u8 {
    var result: [length]u8 = @splat(0);
    @memcpy(result[0..text.len], text);
    return result;
}

pub export var ipmi_event_intf_table: [3]?*EventIntf =
    .{ if (open_enabled) &open_event else &sel_event, if (open_enabled) &sel_event else null, null };

fn usage() void {
    frontend_log.print(log.Level.notice, "Options:", .{});
    frontend_log.print(log.Level.notice, "\ttimeout=#     Time between checks for SEL polling method [default=10]", .{});
    frontend_log.print(log.Level.notice, "\tdaemon        Become a daemon [default]", .{});
    frontend_log.print(log.Level.notice, "\tnodaemon      Do NOT become a daemon", .{});
    frontend_log.print(log.Level.notice, "\tpidfile=PATH  PID file for daemon mode [default=/run/ipmievd.pidN]", .{});
}
fn startsWithIgnoreCase(arg: []const u8, key: []const u8) bool {
    return arg.len >= key.len and std.ascii.eqlIgnoreCase(arg[0..key.len], key);
}
fn options(intf: *Intf, args: []const []const u8) ?bool {
    @memset(&pidfile, 0);
    const default_path = std.fmt.bufPrint(pidfile[0 .. pidfile.len - 1], "/run/ipmievd.pid{d}", .{intf.devnum}) catch unreachable;
    pidfile[default_path.len] = 0;
    selwatch_timeout = 10;
    var daemon = true;
    for (args) |arg| {
        if (std.ascii.eqlIgnoreCase(arg, "help")) {
            usage();
            return null;
        } else if (std.ascii.eqlIgnoreCase(arg, "daemon")) {
            daemon = true;
        } else if (std.ascii.eqlIgnoreCase(arg, "nodaemon")) {
            daemon = false;
        } else if (startsWithIgnoreCase(arg, "daemon=")) {
            const value = arg[7..];
            if (std.ascii.eqlIgnoreCase(value, "on") or std.ascii.eqlIgnoreCase(value, "yes"))
                daemon = true
            else if (std.ascii.eqlIgnoreCase(value, "off") or std.ascii.eqlIgnoreCase(value, "no"))
                daemon = false
            else {
                frontend_log.print(log.Level.err, "Invalid daemon setting", .{});
                return null;
            }
        } else if (startsWithIgnoreCase(arg, "timeout=")) {
            selwatch_timeout = std.fmt.parseInt(c_int, arg[8..], 10) catch {
                frontend_log.print(log.Level.err, "Invalid input given or out of range for time-out.", .{});
                return null;
            };
            if (selwatch_timeout < 0) return null;
        } else if (startsWithIgnoreCase(arg, "pidfile=")) {
            if (arg.len - 8 >= pidfile.len) {
                frontend_log.print(log.Level.err, "The pidfile path is too long. It must be fewer than %d characters", .{@as(c_int, pidfile.len - 1)});
                return null;
            }
            @memset(&pidfile, 0);
            @memcpy(pidfile[0 .. arg.len - 8], arg[8..]);
        }
    }
    return daemon;
}

const Argv = ?[*:null]?[*:0]u8;
fn evdMain(e: *EventIntf, argc: c_int, argv: Argv) callconv(.c) c_int {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(std.heap.c_allocator);
    if (argc > 0 and argv == null) return -1;
    for (0..@intCast(argc)) |i|
        args.append(std.heap.c_allocator, std.mem.span(argv.?[i].?)) catch return -1;
    // Help is a successful early return; invalid options are failures.
    for (args.items) |arg| if (std.ascii.eqlIgnoreCase(arg, "help")) {
        usage();
        return 0;
    };
    const daemon = options(e.intf.?, args.items) orelse return -1;
    @as(*volatile c.sig_atomic_t, @ptrCast(&stop_signal)).* = 0;
    pid_owned = false;
    if (e.intf.?.open.?(e.intf.?) < 0) {
        frontend_log.print(log.Level.err, "Unable to open interface", .{});
        return -1;
    }
    if (daemon) {
        if (io.pid_exists(pidPath())) {
            frontend_log.print(log.Level.err, "PID file '%s' already exists.", .{pidPath()});
            return -1;
        }
        io.daemonize(e.intf.?);
        _ = c.umask(0o22);
        io.install_signals();
        if (!io.pid_write(pidPath())) {
            c.log_halt();
            c.log_init("ipmievd", 1, verbose);
            frontend_log.print(log.Level.err, "Failed to open PID file '%s' for writing.", .{pidPath()});
            return -1;
        }
        pid_owned = true;
    } else {
        io.install_signals();
    }
    defer cleanup();
    c.log_halt();
    c.log_init("ipmievd", @intFromBool(daemon), verbose);
    frontend_log.print(log.Level.notice, "Reading sensors...", .{});
    io.cache(e.intf.?);
    if (stopped()) return 0;
    if (e.setup) |setup| if (setup(e) < 0) {
        frontend_log.print(log.Level.err, "Error setting up Event Interface %s", .{useName(e)});
        return -1;
    };
    frontend_log.print(log.Level.notice, "Waiting for events...", .{});
    if (e.wait) |wait| if (wait(e) < 0) {
        frontend_log.print(log.Level.err, "Error waiting for events!", .{});
        return -1;
    };
    return 0;
}

fn selMain(intf: ?*Intf, argc: c_int, argv: Argv) callconv(.c) c_int {
    const in = intf orelse return -1;
    sel_event.intf = in;
    @memset(&sel_event.prefix, 0);
    if (in.session != null) {
        if (in.ssn_params.hostname) |hostname| {
            const host = std.mem.span(hostname);
            const len = @min(host.len, sel_event.prefix.len - 3);
            @memcpy(sel_event.prefix[0..len], host[0..len]);
            @memcpy(sel_event.prefix[len .. len + 2], ": ");
        }
    }
    return evdMain(&sel_event, argc, argv);
}
fn openMain(intf: ?*Intf, argc: c_int, argv: Argv) callconv(.c) c_int {
    const in = intf orelse return -1;
    if (!std.mem.eql(u8, std.mem.sliceTo(&in.name, 0), "open") or !open_enabled) {
        frontend_log.print(log.Level.err, "Invalid Interface for OpenIPMI Event Handler: %s", .{&in.name});
        return -1;
    }
    open_event.intf = in;
    return evdMain(&open_event, argc, argv);
}
pub export var ipmievd_cmd_list: [if (open_enabled) 3 else 2]Cmd =
    if (open_enabled)
        .{
            .{ .func = openMain, .name = "open", .desc = "Use OpenIPMI for asynchronous notification of events" },
            .{ .func = selMain, .name = "sel", .desc = "Poll SEL for notification of events" },
            .{ .func = null, .name = null, .desc = null },
        }
    else
        .{
            .{ .func = selMain, .name = "sel", .desc = "Poll SEL for notification of events" },
            .{ .func = null, .name = null, .desc = null },
        };

comptime {
    if (!builtin.is_test) {
        @export(&evdMain, .{ .name = "ipmievd_main" });
        @export(&selMain, .{ .name = "ipmievd_sel_main" });
        @export(&openMain, .{ .name = "ipmievd_open_main" });
        @export(&main, .{ .name = "main" });
    }
}
pub fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return @intFromBool(c.ipmi_main(argc, @ptrCast(argv), @ptrCast(&ipmievd_cmd_list), null) < 0);
}

fn testOpenlog(ident: [*c]const u8, option: c_int, facility: c_int) callconv(.c) void {
    _ = option;
    if (builtin.is_test) {
        Fake.syslog_facility = facility;
        Fake.syslog_ident = std.mem.eql(u8, std.mem.span(ident), "ipmievd");
    }
}
comptime {
    if (builtin.is_test) {
        abi.assertCallSignature(@TypeOf(testOpenlog), @TypeOf(c.openlog));
        @export(&testOpenlog, .{ .name = "openlog" });
    }
}

const Fake = if (builtin.is_test) struct {
    var rsp: ipmi.Response = undefined;
    var entries: u16 = 1;
    var info_calls: usize = 0;
    var entry_calls: usize = 0;
    var logged: [8]u16 = @splat(0);
    var log_count: usize = 0;
    var sleep_calls: usize = 0;
    var poll_calls: usize = 0;
    var received: usize = 0;
    var cache_calls: usize = 0;
    var signals_installed: usize = 0;
    var opened: usize = 0;
    var daemonized: usize = 0;
    var written: usize = 0;
    var removed: usize = 0;
    var existing: bool = false;
    var failed_open: bool = false;
    var failed_info: bool = false;
    var info_ccode: bool = false;
    var enable_ccode: bool = false;
    var malformed_info: bool = false;
    var failed_entry: bool = false;
    var malformed_entry: bool = false;
    var failed_write: bool = false;
    var syslog_facility: c_int = -1;
    var syslog_ident: bool = false;
    var failed_ioctl: bool = false;
    var malformed_recv: bool = false;
    var force_poll_error: bool = false;
    var test_path: [64]u8 = @splat(0);

    fn reset() void {
        entries = 1;
        info_calls = 0;
        entry_calls = 0;
        log_count = 0;
        sleep_calls = 0;
        poll_calls = 0;
        received = 0;
        cache_calls = 0;
        signals_installed = 0;
        opened = 0;
        daemonized = 0;
        written = 0;
        removed = 0;
        existing = false;
        failed_open = false;
        failed_info = false;
        info_ccode = false;
        enable_ccode = false;
        malformed_info = false;
        failed_entry = false;
        malformed_entry = false;
        failed_write = false;
        syslog_facility = -1;
        syslog_ident = false;
        failed_ioctl = false;
        malformed_recv = false;
        force_poll_error = false;
        @memset(&test_path, 0);
        @as(*volatile c.sig_atomic_t, @ptrCast(&stop_signal)).* = 0;
        selwatch_count = 0;
        selwatch_lastid = 0;
        selwatch_pctused = 0;
        selwatch_overflow = 0;
        io = .{
            .ioctl = ioctl,
            .poll = poll,
            .sleep = sleep,
            .daemonize = daemonize,
            .cache = cache,
            .install_signals = installSignals,
            .pid_exists = pidExists,
            .pid_write = pidWrite,
            .pid_remove = pidRemove,
        };
    }
    fn interface() Intf {
        var intf = std.mem.zeroes(Intf);
        intf.fd = 42;
        intf.devnum = 7;
        intf.name = padded(16, "open");
        intf.open = openIntf;
        intf.sendrecv = sendrecv;
        return intf;
    }
    fn sendrecv(_: *Intf, req: *ipmi.Request) callconv(.c) ?*ipmi.Response {
        rsp = std.mem.zeroes(ipmi.Response);
        switch (req.msg.cmd) {
            c.IPMI_CMD_GET_SEL_INFO => {
                info_calls += 1;
                if (failed_info) return null;
                if (info_ccode) rsp.ccode = 0xc1;
                rsp.data_len = if (malformed_info) 4 else 14;
                rsp.data[1] = @truncate(entries);
                rsp.data[2] = @truncate(entries >> 8);
                rsp.data[3] = 0xe0;
                rsp.data[4] = 1;
                return &rsp;
            },
            c.IPMI_CMD_GET_SEL_ENTRY => {
                entry_calls += 1;
                if (failed_entry) return null;
                rsp.data_len = if (malformed_entry) 5 else 18;
                const id: u16 = std.mem.readInt(u16, req.msg.data.?[2..4], .little);
                const record_id: u16 = if (id == 0) 1 else id;
                const next: u16 = if (record_id < entries) record_id + 1 else 0xffff;
                std.mem.writeInt(u16, rsp.data[0..2], next, .little);
                std.mem.writeInt(u16, rsp.data[2..4], record_id, .little);
                rsp.data[4] = 0xc1;
                return &rsp;
            },
            0x2f => {
                if (enable_ccode) rsp.ccode = 0xc1;
                rsp.data_len = 1;
                rsp.data[0] = 0x10;
                return &rsp;
            },
            0x2e => {
                rsp.data_len = 0;
                if (req.msg.data == null or req.msg.data.?[0] != 0x14) return null;
                return &rsp;
            },
            else => return null,
        }
    }
    fn logEvent(_: *EventIntf, evt: *Event) callconv(.c) void {
        logged[log_count] = evt.record_id;
        log_count += 1;
    }
    fn openIntf(_: *Intf) callconv(.c) c_int {
        opened += 1;
        return if (failed_open) -1 else 0;
    }
    fn ioctl(_: c_int, request: c_ulong, arg: ?*anyopaque) c_int {
        if (failed_ioctl) return -1;
        if (request == open.ipmictl_set_gets_events_cmd) {
            const flag: *c_int = @ptrCast(@alignCast(arg.?));
            return if (flag.* == 1) 0 else -1;
        }
        if (request != open.ipmictl_receive_msg_trunc) return -1;
        received += 1;
        const recv: *open.Recv = @ptrCast(@alignCast(arg.?));
        recv.recv_type = c.IPMI_ASYNC_EVENT_RECV_TYPE;
        recv.msg.data_len = if (malformed_recv) 3 else 16;
        @memset(recv.msg.data.?[0..16], 0);
        recv.msg.data.?[0] = 9;
        recv.msg.data.?[2] = 0xc1;
        return 0;
    }
    fn poll(fds: [*c]c.struct_pollfd, _: c.nfds_t, _: c_int) c_int {
        poll_calls += 1;
        if (force_poll_error) {
            std.c._errno().* = c.EIO;
            return -1;
        }
        if (poll_calls == 1) {
            fds[0].revents = c.POLLIN;
            return 1;
        }
        onSignal(c.SIGTERM);
        std.c._errno().* = c.EINTR;
        return -1;
    }
    fn sleep(_: c_uint) c_uint {
        sleep_calls += 1;
        onSignal(c.SIGTERM);
        return 0;
    }
    fn daemonize(_: *Intf) void {
        daemonized += 1;
    }
    fn cache(_: *Intf) void {
        cache_calls += 1;
    }
    fn installSignals() void {
        signals_installed += 1;
    }
    fn pidExists(_: [*:0]const u8) bool {
        return existing;
    }
    fn pidWrite(path: [*:0]const u8) bool {
        written += 1;
        const text = std.mem.span(path);
        @memcpy(test_path[0..text.len], text);
        return !failed_write;
    }
    fn pidRemove(path: [*:0]const u8) void {
        std.debug.assert(std.mem.eql(u8, std.mem.span(path), std.mem.sliceTo(&test_path, 0)));
        removed += 1;
    }
    fn wait(e: *EventIntf) callconv(.c) c_int {
        _ = e;
        onSignal(c.SIGTERM);
        return 0;
    }
    fn setupFail(_: *EventIntf) callconv(.c) c_int {
        return -1;
    }
} else struct {};

test "SEL polling detects only new events, no event sleeps and SIGTERM stops" {
    Fake.reset();
    defer io = .{};
    var intf = Fake.interface();
    var e = sel_event;
    e.intf = &intf;
    e.log_event = Fake.logEvent;
    try std.testing.expectEqual(@as(c_int, 0), selSetup(&e));
    try std.testing.expectEqual(@as(u16, 1), selwatch_lastid);
    try std.testing.expectEqual(@as(c_int, 0), selCheck(&e));
    try std.testing.expectEqual(@as(usize, 0), Fake.log_count);
    try std.testing.expectEqual(@as(c_int, 0), selWait(&e));
    try std.testing.expectEqual(@as(usize, 1), Fake.sleep_calls);
    Fake.reset();
    e.intf = &intf;
    e.log_event = Fake.logEvent;
    try std.testing.expectEqual(@as(c_int, 0), selSetup(&e));
    Fake.entries = 2;
    try std.testing.expectEqual(@as(c_int, 1), selCheck(&e));
    try std.testing.expectEqual(@as(c_int, 0), selRead(&e));
    try std.testing.expectEqual(@as(usize, 1), Fake.log_count);
    try std.testing.expectEqual(@as(u16, 2), Fake.logged[0]);
    try std.testing.expectEqual(@as(u16, 2), selwatch_lastid);
    Fake.entries = 0;
    try std.testing.expectEqual(@as(c_int, 0), selCheck(&e));
    try std.testing.expectEqual(@as(u16, 0), selwatch_lastid);
}

test "SEL errors and malformed responses do not emit events or spin" {
    Fake.reset();
    defer io = .{};
    var intf = Fake.interface();
    var e = sel_event;
    e.intf = &intf;
    e.log_event = Fake.logEvent;
    Fake.malformed_info = true;
    try std.testing.expectEqual(@as(c_int, -1), selSetup(&e));
    Fake.malformed_info = false;
    Fake.info_ccode = true;
    try std.testing.expectEqual(@as(c_int, -1), selSetup(&e));
    Fake.info_ccode = false;
    try std.testing.expectEqual(@as(c_int, 0), selSetup(&e));
    Fake.failed_info = true;
    try std.testing.expectEqual(@as(c_int, -1), selWait(&e));
    try std.testing.expectEqual(@as(usize, 0), Fake.sleep_calls);
    Fake.failed_info = false;
    Fake.entries = 2;
    try std.testing.expectEqual(@as(c_int, 1), selCheck(&e));
    Fake.malformed_entry = true;
    try std.testing.expectEqual(@as(c_int, -1), selRead(&e));
    try std.testing.expectEqual(@as(usize, 0), Fake.log_count);
    Fake.malformed_entry = false;
    Fake.failed_entry = true;
    try std.testing.expectEqual(@as(c_int, -1), selRead(&e));
    try std.testing.expectEqual(@as(u16, 1), selwatch_lastid);
}

test "OpenIPMI enables buffer, receives events, rejects truncation and handles poll errors" {
    Fake.reset();
    defer io = .{};
    var intf = Fake.interface();
    var e = open_event;
    e.intf = &intf;
    e.log_event = Fake.logEvent;
    try std.testing.expectEqual(@as(c_int, 0), openSetup(&e));
    try std.testing.expectEqual(@as(c_int, 0), openWait(&e));
    try std.testing.expectEqual(@as(usize, 1), Fake.received);
    try std.testing.expectEqual(@as(usize, 1), Fake.log_count);
    try std.testing.expectEqual(@as(u16, 9), Fake.logged[0]);
    Fake.reset();
    e.intf = &intf;
    e.log_event = Fake.logEvent;
    Fake.malformed_recv = true;
    try std.testing.expectEqual(@as(c_int, -1), openWait(&e));
    try std.testing.expectEqual(@as(usize, 0), Fake.log_count);
    Fake.force_poll_error = true;
    try std.testing.expectEqual(@as(c_int, -1), openWait(&e));
    Fake.failed_ioctl = true;
    try std.testing.expectEqual(@as(c_int, -1), openSetup(&e));
    Fake.failed_ioctl = false;
    Fake.enable_ccode = true;
    try std.testing.expectEqual(@as(c_int, -1), openSetup(&e));
}

test "daemon, foreground, signal and PID lifecycle use the real entrypoint" {
    Fake.reset();
    defer io = .{};
    var intf = Fake.interface();
    var e = sel_event;
    e.intf = &intf;
    e.setup = null;
    e.wait = Fake.wait;
    const daemon_args: [3:null]?[*:0]u8 = .{
        @constCast("daemon"), @constCast("pidfile=evd-test.pid"), null,
    };
    try std.testing.expectEqual(@as(c_int, 0), evdMain(&e, 2, @constCast(daemon_args[0..2 :null].ptr)));
    try std.testing.expectEqual(@as(usize, 1), Fake.daemonized);
    try std.testing.expectEqual(@as(usize, 1), Fake.written);
    try std.testing.expectEqual(@as(usize, 1), Fake.removed);
    try std.testing.expectEqualStrings("evd-test.pid", std.mem.sliceTo(&Fake.test_path, 0));
    try std.testing.expectEqual(@as(usize, 1), Fake.cache_calls);
    try std.testing.expectEqual(@as(usize, 1), Fake.signals_installed);
    try std.testing.expectEqual(@as(c_int, c.LOG_LOCAL4), Fake.syslog_facility);
    try std.testing.expect(Fake.syslog_ident);

    Fake.reset();
    const foreground_args: [2:null]?[*:0]u8 = .{ @constCast("nodaemon"), null };
    try std.testing.expectEqual(@as(c_int, 0), evdMain(&e, 1, @constCast(foreground_args[0..1 :null].ptr)));
    try std.testing.expectEqual(@as(usize, 0), Fake.daemonized);
    try std.testing.expectEqual(@as(usize, 0), Fake.written);
    try std.testing.expectEqual(@as(usize, 0), Fake.removed);
    try std.testing.expectEqual(@as(c_int, -1), Fake.syslog_facility);
    Fake.reset();
    Fake.existing = true;
    try std.testing.expectEqual(@as(c_int, -1), evdMain(&e, 2, @constCast(daemon_args[0..2 :null].ptr)));
    try std.testing.expectEqual(@as(usize, 0), Fake.daemonized);
    Fake.reset();
    Fake.failed_write = true;
    try std.testing.expectEqual(@as(c_int, -1), evdMain(&e, 2, @constCast(daemon_args[0..2 :null].ptr)));
    try std.testing.expectEqual(@as(usize, 1), Fake.daemonized);
    try std.testing.expectEqual(@as(usize, 0), Fake.removed);
    Fake.reset();
    e.setup = Fake.setupFail;
    try std.testing.expectEqual(@as(c_int, -1), evdMain(&e, 2, @constCast(daemon_args[0..2 :null].ptr)));
    try std.testing.expectEqual(@as(usize, 1), Fake.removed);
    e.setup = null;
    Fake.reset();
    Fake.failed_open = true;
    try std.testing.expectEqual(@as(c_int, -1), evdMain(&e, 1, @constCast(foreground_args[0..1 :null].ptr)));
    try std.testing.expectEqual(@as(usize, 0), Fake.signals_installed);
}

test "daemon option parsing validates timeout and PID path length" {
    Fake.reset();
    defer io = .{};
    var intf = Fake.interface();
    try std.testing.expectEqual(@as(?bool, false), options(&intf, &.{ "daemon=off", "timeout=30" }));
    try std.testing.expectEqual(@as(c_int, 30), selwatch_timeout);
    try std.testing.expectEqual(@as(?bool, null), options(&intf, &.{"timeout=-1"}));
    try std.testing.expectEqual(@as(?bool, null), options(&intf, &.{"timeout=invalid"}));
    try std.testing.expectEqual(@as(?bool, null), options(&intf, &.{"pidfile=" ++ "x" ** 64}));
    try std.testing.expectEqual(@as(?bool, true), options(&intf, &.{"daemon=yes"}));
    try std.testing.expectEqualStrings("/run/ipmievd.pid7", std.mem.span(pidPath()));
}
