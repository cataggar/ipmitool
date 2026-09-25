//! AMI virtual-CD USB transport, ported from `src/plugins/usb/usb.c`.
//!
//! This is a Linux SCSI generic transport, not a libusb transport.  It scans
//! `/proc/scsi/sg/device_strs` for AMI, identifies `/dev/sgN` with command
//! 0xee, and exchanges native-endian command headers and data via SG_IO.
//! Tests replace only the file/device syscalls; the production packet and
//! response logic is exercised unchanged against a model SCSI device.

const builtin = @import("builtin");
const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("intf.zig").Intf;
const log = @import("../util/log.zig");

const signature = "$G2-CONFIG-HOST$";
const max_request_size = 64 * 1024;
const max_scsi_transfer = std.math.maxInt(u16);
const cmd_sector: u8 = 1;
const data_sector: u8 = 2;
const identify_op: u8 = 0xee;
const write_op: u8 = 0xe2;
const read_op: u8 = 0xe3;
const in_process: u16 = 0x8000;

pub const ConfigCmd = extern struct {
    BeginSig: [16]u8,
    Command: u16,
    Status: u16,
    DataInLen: u32,
    DataOutLen: u32,
    InternalUseDataIn: u32,
    InternalUseDataOut: u32,
};

comptime {
    if (builtin.target.os.tag != .linux) @compileError("AMI USB requires Linux SG_IO");
    abi.assertLayout(ConfigCmd, c.CONFIG_CMD);
}

// ModelDevice is present in the test binary only.  In a normal binary these
// calls resolve directly to libc; no test device or alternate path is linked.
fn sysFopen(path: [*:0]const u8, mode: [*:0]const u8) ?*c.FILE {
    if (builtin.is_test) return ModelDevice.fopen(path, mode);
    return c.fopen(path, mode);
}

fn sysFgets(buf: [*c]u8, size: c_int, stream: *c.FILE) [*c]u8 {
    if (builtin.is_test) return ModelDevice.fgets(buf, size, stream);
    return c.fgets(buf, size, stream);
}

fn sysFclose(stream: *c.FILE) c_int {
    if (builtin.is_test) return ModelDevice.fclose(stream);
    return c.fclose(stream);
}

fn sysOpen(path: [*:0]const u8, flags: c_int) c_int {
    if (builtin.is_test) return ModelDevice.open(path, flags);
    return c.open(path, flags);
}

fn sysClose(fd: c_int) c_int {
    if (builtin.is_test) return ModelDevice.close(fd);
    return c.close(fd);
}

fn sysFlock(fd: c_int, op: c_int) c_int {
    if (builtin.is_test) return ModelDevice.flock(fd, op);
    return c.flock(fd, op);
}

fn sysIoctl(fd: c_int, hdr: *c.sg_io_hdr_t) c_int {
    if (builtin.is_test) return ModelDevice.ioctl(fd, hdr);
    return c.ioctl(fd, c.SG_IO, hdr);
}

fn sysSleep() void {
    if (builtin.is_test) {
        ModelDevice.sleep();
    } else {
        _ = c.usleep(1000);
    }
}

fn scsiProbeNew(num_ami_devices: *c_int, sg_nos: [*c]c_int) callconv(.c) c_int {
    const capacity = num_ami_devices.*;
    const fp = sysFopen("/proc/scsi/sg/device_strs", "r") orelse return 1;
    defer _ = sysFclose(fp);
    num_ami_devices.* = 0;

    var line: [81]u8 = undefined;
    var lineno: c_int = 0;
    while (sysFgets(&line, 80, fp) != null) {
        // sscanf("%s") counted only lines with a first word.  Unlike that
        // unbounded scan, this cannot write beyond the local vendor buffer.
        const text = std.mem.sliceTo(&line, 0);
        var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
        const vendor = words.next() orelse continue;
        if (std.mem.eql(u8, vendor, "AMI") and num_ami_devices.* < capacity) {
            sg_nos[@intCast(num_ami_devices.*)] = lineno;
            num_ami_devices.* += 1;
            if (num_ami_devices.* == capacity) break;
        }
        lineno += 1;
    }
    return 0;
}

fn openCD(intf: *Intf, name: [*c]u8) callconv(.c) c_int {
    intf.fd = sysOpen(@ptrCast(name), c.O_RDWR);
    if (intf.fd == -1) {
        log.print(log.Level.err, "OpenCD:Unable to open device, %s", .{c.strerror(std.c._errno().*)});
        return 1;
    }
    return 0;
}

fn sendScsiCmd(
    fd: c_int,
    cdb: [*c]u8,
    cdb_len: u8,
    data: ?*anyopaque,
    data_len: *c_uint,
    direction: c_int,
    sense: ?*anyopaque,
    sense_len: u8,
    timeout: c_uint,
) callconv(.c) c_int {
    var hdr: c.sg_io_hdr_t = std.mem.zeroes(c.sg_io_hdr_t);
    hdr.interface_id = 'S';
    hdr.cmd_len = cdb_len;
    hdr.dxfer_direction = direction;
    hdr.dxfer_len = data_len.*;
    hdr.dxferp = data;
    hdr.cmdp = cdb;
    hdr.sbp = @ptrCast(sense);
    hdr.mx_sb_len = sense_len;
    hdr.timeout = if (timeout == 0) 20000 else timeout;

    if (sysIoctl(fd, &hdr) < 0) {
        log.print(log.Level.err, "sendscsicmd_SGIO: SG_IO ioctl error", .{});
        return 1;
    }
    if (hdr.status != 0) return 1;
    if (timeout != 0 and (hdr.info & c.SG_INFO_OK_MASK) != c.SG_INFO_OK) {
        log.print(log.Level.debug, "sendscsicmd_SGIO: SG_INFO_OK - Not OK", .{});
        return 1;
    }
    // A successful status with a short read is not a complete header, ID or
    // response; consuming its uninitialised tail would be unsafe.
    if (direction == c.SG_DXFER_FROM_DEV and hdr.resid != 0) return 1;
    return 0;
}

fn identify(fd: c_int, sig: [*c]u8) callconv(.c) c_int {
    var cdb: [10]u8 = @splat(0);
    cdb[0] = identify_op;
    var len: c_uint = 10;
    return sendScsiCmd(fd, &cdb, cdb.len, sig, &len, c.SG_DXFER_FROM_DEV, null, 0, 5000);
}

fn isG2Drive(fd: c_int) callconv(.c) c_int {
    var sig: [15]u8 = @splat(0);
    _ = sysFlock(fd, c.LOCK_EX);
    const rc = identify(fd, &sig);
    _ = sysFlock(fd, c.LOCK_UN);
    if (rc != 0) {
        log.print(log.Level.debug, "IsG2Drive:Unable to send ID command to the device", .{});
        return 1;
    }
    if (!std.mem.eql(u8, std.mem.sliceTo(&sig, 0), "$$$AMI$$$")) {
        log.print(log.Level.err, "IsG2Drive:Signature mismatch when ID command sent", .{});
        return 1;
    }
    return 0;
}

fn findG2CDROM(intf: *Intf) callconv(.c) c_int {
    var devices: [16]c_int = undefined;
    var count: c_int = devices.len;
    if (scsiProbeNew(&count, &devices) != 0 or count == 0) {
        log.print(log.Level.debug, "Unable to find Virtual CDROM Device", .{});
        return 0;
    }
    for (devices[0..@intCast(count)]) |number| {
        var name: [256]u8 = undefined;
        _ = c.sprintf(&name, "/dev/sg%d", number);
        if (openCD(intf, &name) != 0) continue;
        if (isG2Drive(intf.fd) == 0) {
            log.print(log.Level.debug, "USB Device found", .{});
            return 1;
        }
        _ = sysClose(intf.fd);
        intf.fd = -1;
    }
    return 0;
}

fn setup(intf: *Intf) callconv(.c) c_int {
    if (findG2CDROM(intf) == 0) {
        log.print(log.Level.err, "Error in USB session setup", .{});
        return -1;
    }
    intf.opened = 1;
    return 0;
}

fn close(intf: *Intf) callconv(.c) void {
    if (intf.fd >= 0 and intf.opened != 0) _ = sysClose(intf.fd);
    intf.fd = -1;
    intf.opened = 0;
}

fn initCmdHeader(header: *ConfigCmd) callconv(.c) void {
    header.* = std.mem.zeroes(ConfigCmd);
    @memcpy(&header.BeginSig, signature);
}

fn scsiData(fd: c_int, buf: [*c]u8, sector: u8, len: u16, timeout: c_uint, op: u8) c_int {
    var cdb: [10]u8 = @splat(0);
    cdb[0] = op;
    std.mem.writeInt(u32, cdb[2..6], sector, .big);
    std.mem.writeInt(u16, cdb[7..9], 1, .big);
    var sense: [32]u8 = undefined;
    var transfer_len: c_uint = len;
    const direction = if (op == write_op) c.SG_DXFER_TO_DEV else c.SG_DXFER_FROM_DEV;
    var retries: u8 = 3;
    while (retries > 0) : (retries -= 1) {
        if (sendScsiCmd(fd, &cdb, cdb.len, buf, &transfer_len, direction, &sense, sense.len, timeout) == 0) return 0;
    }
    return -1;
}

fn sendCmd(fd: c_int, buf: [*c]u8, sector: u8, len: u16, timeout: c_uint) callconv(.c) c_int {
    return scsiData(fd, buf, sector, len, timeout, write_op);
}

fn recvCmd(fd: c_int, buf: [*c]u8, sector: u8, len: u16) callconv(.c) c_int {
    return scsiData(fd, buf, sector, len, 5000, read_op);
}

fn readCD(fd: c_int, sector: u8, buf: [*c]u8, len: u32) callconv(.c) c_int {
    if (len > max_scsi_transfer or recvCmd(fd, buf, sector, @intCast(len)) != 0) {
        log.print(log.Level.err, "Error while reading CD-Drive", .{});
        return -1;
    }
    return 0;
}

fn writeCD(fd: c_int, sector: u8, buf: [*c]u8, timeout: c_uint, len: u32) callconv(.c) c_int {
    if (len > max_scsi_transfer or sendCmd(fd, buf, sector, @intCast(len), timeout) != 0) {
        log.print(log.Level.err, "Error while writing to CD-Drive", .{});
        return -1;
    }
    return 0;
}

fn writeSplitData(intf: *Intf, buf: [*c]u8, sector: u8, len: u32, timeout: u32) callconv(.c) c_int {
    // Despite its name the C implementation performs one write.  Reject an
    // unrepresentable length rather than silently truncating its u16 argument.
    if (len == 0) return 0;
    return writeCD(intf.fd, sector, buf, timeout, len);
}

fn readSplitData(intf: *Intf, buf: [*c]u8, sector: u8, len: u32) callconv(.c) c_int {
    if (len == 0) return 0;
    return if (readCD(intf.fd, sector, buf, len) == 0) 0 else 1;
}

fn waitForCompletion(intf: *Intf, header: *ConfigCmd, timeout: u32, len: u32) callconv(.c) c_int {
    if (len != @sizeOf(ConfigCmd)) return 1;
    var elapsed: u32 = 0;
    while (true) {
        if (readCD(intf.fd, cmd_sector, @ptrCast(header), len) != 0) {
            log.print(log.Level.err, "ReadCD returned ERROR", .{});
            return 1;
        }
        if (header.Status & in_process == 0) {
            log.print(log.Level.debug, "Command completed", .{});
            return 0;
        }
        sysSleep();
        if (timeout > 0) {
            elapsed += 1;
            if (elapsed > timeout) return 2;
        }
    }
}

fn sendData(
    intf: *Intf,
    request: [*c]u8,
    request_len: c_uint,
    response: [*c]u8,
    response_len: *c_int,
    timeout: c_uint,
) callconv(.c) c_int {
    if (request_len > max_request_size or request_len > max_scsi_transfer or
        response_len.* < 0 or response_len.* > ipmi.buf_size or
        (request_len > 0 and request == null) or (response_len.* > 0 and response == null))
    {
        return -1;
    }
    const capacity: u32 = @intCast(response_len.*);
    var header: ConfigCmd = undefined;
    initCmdHeader(&header);
    header.DataOutLen = capacity;
    header.DataInLen = request_len;
    const initial_timeout: u32 = if (timeout == 0) 3000 else 0;
    if (writeCD(intf.fd, cmd_sector, @ptrCast(&header), initial_timeout, @sizeOf(ConfigCmd)) != 0) {
        log.print(log.Level.err, "Error in Write CD of SCSI_AMIDEF_CMD_SECTOR", .{});
        return -1;
    }
    if (writeSplitData(intf, request, data_sector, request_len, timeout) != 0) {
        log.print(log.Level.err, "Error in WriteSplitData of SCSI_AMIDEF_DATA_SECTOR", .{});
        return -1;
    }
    if (timeout == 0) {
        return 0;
    }
    const waited = waitForCompletion(intf, &header, timeout, @sizeOf(ConfigCmd));
    if (waited != 0) {
        log.print(log.Level.err, "WaitForCommandComplete failed", .{});
        return -waited;
    }
    switch (header.Status) {
        0 => {
            if (header.DataOutLen > capacity or header.DataOutLen > max_scsi_transfer) return -1;
            if (readSplitData(intf, response, data_sector, header.DataOutLen) != 0) {
                log.print(log.Level.err, "Err ReadSplitData SCSI_AMIDEF_DATA_SCTR", .{});
                return -1;
            }
            response_len.* = @intCast(header.DataOutLen);
            // Upstream always rereads the command sector after the payload.
            // Do not silently ignore an I/O error reported by that read.
            if (readCD(intf.fd, cmd_sector, @ptrCast(&header), @sizeOf(ConfigCmd)) != 0) return -1;
            return 0;
        },
        1 => log.print(log.Level.err, "Too much data", .{}),
        2 => log.print(log.Level.err, "Too little data", .{}),
        3 => log.print(log.Level.err, "Unsupported command", .{}),
        else => log.print(log.Level.err, "Unknown status", .{}),
    }
    return header.Status;
}

var rsp: ipmi.Response = std.mem.zeroes(ipmi.Response);

fn sendrecv(intf: *Intf, req: *ipmi.Request) callconv(.c) ?*ipmi.Response {
    rsp = std.mem.zeroes(ipmi.Response);
    const len: usize = @as(usize, req.msg.data_len) + 2;
    if (len > max_request_size or len > max_scsi_transfer or
        (req.msg.data_len > 0 and req.msg.data == null))
    {
        rsp.ccode = 0xff;
        return &rsp;
    }
    var packet: [max_request_size]u8 = @splat(0);
    packet[0] = (@as(u8, req.msg.netfn_lun.netfn) << 2) | req.msg.netfn_lun.lun;
    packet[1] = req.msg.cmd;
    if (req.msg.data_len != 0) {
        @memcpy(packet[2..len], req.msg.data.?[0..req.msg.data_len]);
    }

    var rc: c_int = -1;
    var reply_len: c_int = 0;
    for (0..3) |_| {
        reply_len = rsp.data.len;
        rc = sendData(intf, &packet, @intCast(len), &rsp.data, &reply_len, 20000);
        if (rc == 0) break;
    }
    if (rc != 0 or reply_len < 1) {
        log.print(log.Level.err, "Error while sending command using SendDataToUSBDriver", .{});
        rsp.ccode = if (rc != 0) @truncate(@as(u32, @bitCast(rc))) else 0xff;
        rsp.data_len = 0;
        return &rsp;
    }
    rsp.ccode = rsp.data[0];
    if (rsp.ccode == 0) {
        const payload_len: usize = @intCast(reply_len - 1);
        std.mem.copyForwards(u8, rsp.data[0..payload_len], rsp.data[1..@intCast(reply_len)]);
        rsp.data[payload_len] = 0;
        rsp.data_len = @intCast(payload_len);
    } else {
        rsp.data_len = reply_len;
    }
    return &rsp;
}

var usb_intf: Intf = blk: {
    var i: Intf = std.mem.zeroes(Intf);
    const name = "usb";
    const desc = "IPMI USB Interface(OEM Interface for AMI Devices)";
    @memcpy(i.name[0..name.len], name);
    @memcpy(i.desc[0..desc.len], desc);
    i.setup = setup;
    i.close = close;
    i.sendrecv = sendrecv;
    break :blk i;
};

pub fn exportSymbols() void {
    @setEvalBranchQuota(100000);
    const symbols = .{
        .{ &scsiProbeNew, "scsiProbeNew", c.scsiProbeNew },
        .{ &openCD, "OpenCD", c.OpenCD },
        .{ &sendScsiCmd, "sendscsicmd_SGIO", c.sendscsicmd_SGIO },
        .{ &identify, "AMI_SPT_CMD_Identify", c.AMI_SPT_CMD_Identify },
        .{ &isG2Drive, "IsG2Drive", c.IsG2Drive },
        .{ &findG2CDROM, "FindG2CDROM", c.FindG2CDROM },
        .{ &initCmdHeader, "InitCmdHeader", c.InitCmdHeader },
        .{ &sendCmd, "AMI_SPT_CMD_SendCmd", c.AMI_SPT_CMD_SendCmd },
        .{ &recvCmd, "AMI_SPT_CMD_RecvCmd", c.AMI_SPT_CMD_RecvCmd },
        .{ &readCD, "ReadCD", c.ReadCD },
        .{ &writeCD, "WriteCD", c.WriteCD },
        .{ &writeSplitData, "WriteSplitData", c.WriteSplitData },
        .{ &readSplitData, "ReadSplitData", c.ReadSplitData },
        .{ &waitForCompletion, "WaitForCommandCompletion", c.WaitForCommandCompletion },
        .{ &sendData, "SendDataToUSBDriver", c.SendDataToUSBDriver },
    };
    inline for (symbols) |symbol| {
        abi.assertCallSignature(@TypeOf(symbol[0].*), @TypeOf(symbol[2]));
        @export(symbol[0], .{ .name = symbol[1] });
    }
    @export(&usb_intf, .{ .name = "ipmi_usb_intf" });
}

const ModelDevice = if (builtin.is_test) struct {
    const Self = @This();
    const Operation = struct {
        opcode: u8,
        sector: u32,
        direction: c_int,
        len: u32,
        timeout: u32,
    };

    const file: *c.FILE = @ptrFromInt(0x1000);
    var lines: []const []const u8 = &.{"AMI Virtual CD\n"};
    var file_available: bool = true;
    var line_index: usize = 0;
    var file_closed: bool = false;
    var attempts: [16][32]u8 = @splat(@splat(0));
    var open_count: usize = 0;
    var close_count: usize = 0;
    var identify_number: c_int = 0;
    var fail_open: c_int = -1;
    var lock_count: usize = 0;
    var unlock_count: usize = 0;
    var operations: [64]Operation = undefined;
    var operation_count: usize = 0;
    var complaints: usize = 0;
    var fail_opcode: u8 = 0;
    var fail_sector: u32 = 0;
    var failures_left: usize = 0;
    var fail_post_read: bool = false;
    var bad_info: bool = false;
    var short_read: bool = false;
    var statuses: []const u16 = &.{0};
    var status_read_count: usize = 0;
    var sleeps: usize = 0;
    var response: []const u8 = &.{ 0, 0x42 };
    var outlen_override: ?u32 = null;
    var header: ConfigCmd = undefined;
    var payload: [1024]u8 = @splat(0);
    var payload_len: usize = 0;

    fn reset() void {
        lines = &.{"AMI Virtual CD\n"};
        file_available = true;
        line_index = 0;
        file_closed = false;
        attempts = @splat(@splat(0));
        open_count = 0;
        close_count = 0;
        identify_number = 0;
        fail_open = -1;
        lock_count = 0;
        unlock_count = 0;
        operation_count = 0;
        complaints = 0;
        fail_opcode = 0;
        fail_sector = 0;
        failures_left = 0;
        fail_post_read = false;
        bad_info = false;
        short_read = false;
        statuses = &.{0};
        status_read_count = 0;
        sleeps = 0;
        response = &.{ 0, 0x42 };
        outlen_override = null;
        header = std.mem.zeroes(ConfigCmd);
        payload = @splat(0);
        payload_len = 0;
        rsp = std.mem.zeroes(ipmi.Response);
    }

    fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*c.FILE {
        if (!std.mem.eql(u8, std.mem.sliceTo(path, 0), "/proc/scsi/sg/device_strs") or
            !std.mem.eql(u8, std.mem.sliceTo(mode, 0), "r")) complaints += 1;
        if (!file_available) return null;
        return file;
    }

    fn fgets(buf: [*c]u8, size: c_int, stream: *c.FILE) [*c]u8 {
        if (stream != file or size != 80) complaints += 1;
        if (line_index >= lines.len) return null;
        const line = lines[line_index];
        line_index += 1;
        const n = @min(line.len, @as(usize, @intCast(size - 1)));
        @memcpy(buf[0..n], line[0..n]);
        buf[n] = 0;
        return buf;
    }

    fn fclose(stream: *c.FILE) c_int {
        if (stream != file) complaints += 1;
        file_closed = true;
        return 0;
    }

    fn open(path: [*:0]const u8, flags: c_int) c_int {
        const text = std.mem.sliceTo(path, 0);
        if (flags != c.O_RDWR or !std.mem.startsWith(u8, text, "/dev/sg")) complaints += 1;
        if (open_count < attempts.len and text.len < attempts[0].len) {
            @memcpy(attempts[open_count][0..text.len], text);
        } else complaints += 1;
        open_count += 1;
        const number = std.fmt.parseInt(c_int, text[7..], 10) catch {
            complaints += 1;
            return -1;
        };
        return if (number == fail_open) -1 else 200 + number;
    }

    fn close(fd: c_int) c_int {
        if (fd < 200) complaints += 1;
        close_count += 1;
        return 0;
    }

    fn flock(fd: c_int, op: c_int) c_int {
        if (fd < 200) complaints += 1;
        if (op == c.LOCK_EX) {
            lock_count += 1;
        } else if (op == c.LOCK_UN) {
            unlock_count += 1;
        } else complaints += 1;
        return 0;
    }

    fn sleep() void {
        sleeps += 1;
    }

    fn ioctl(fd: c_int, hdr: *c.sg_io_hdr_t) c_int {
        if (fd < 200 or hdr.interface_id != 'S' or hdr.cmd_len != 10 or hdr.mx_sb_len > 32) {
            complaints += 1;
            return -1;
        }
        const cdb = hdr.cmdp[0..hdr.cmd_len];
        const opcode = cdb[0];
        const sector = std.mem.readInt(u32, cdb[2..6], .big);
        if (opcode != identify_op and
            (cdb[6] != 0 or std.mem.readInt(u16, cdb[7..9], .big) != 1 or cdb[9] != 0))
        {
            complaints += 1;
            return -1;
        }
        if (operation_count < operations.len) {
            operations[operation_count] = .{
                .opcode = opcode,
                .sector = sector,
                .direction = hdr.dxfer_direction,
                .len = hdr.dxfer_len,
                .timeout = hdr.timeout,
            };
        } else complaints += 1;
        operation_count += 1;
        if (failures_left > 0 and opcode == fail_opcode and sector == fail_sector) {
            failures_left -= 1;
            return -1;
        }
        if (fail_post_read and opcode == read_op and sector == cmd_sector and status_read_count > 0) return -1;
        hdr.info = if (bad_info) 1 else c.SG_INFO_OK;
        hdr.resid = if (short_read and hdr.dxfer_direction == c.SG_DXFER_FROM_DEV) 1 else 0;
        const buffer: [*]u8 = @ptrCast(hdr.dxferp.?);
        if (opcode == identify_op) {
            if (hdr.dxfer_direction != c.SG_DXFER_FROM_DEV or hdr.dxfer_len != 10 or hdr.timeout != 5000) complaints += 1;
            @memcpy(buffer[0..10], if (fd == 200 + identify_number) "$$$AMI$$$\x00" else "NOT-AMI!!\x00");
            return 0;
        }
        if (opcode == write_op and sector == cmd_sector) {
            if (hdr.dxfer_direction != c.SG_DXFER_TO_DEV or hdr.dxfer_len != @sizeOf(ConfigCmd)) complaints += 1;
            @memcpy(std.mem.asBytes(&header), buffer[0..@sizeOf(ConfigCmd)]);
        } else if (opcode == write_op and sector == data_sector) {
            if (hdr.dxfer_direction != c.SG_DXFER_TO_DEV or hdr.dxfer_len > payload.len) complaints += 1;
            payload_len = @min(payload.len, hdr.dxfer_len);
            @memcpy(payload[0..payload_len], buffer[0..payload_len]);
        } else if (opcode == read_op and sector == cmd_sector) {
            if (hdr.dxfer_direction != c.SG_DXFER_FROM_DEV or hdr.dxfer_len != @sizeOf(ConfigCmd)) complaints += 1;
            const index = @min(status_read_count, statuses.len - 1);
            var result = header;
            result.Status = statuses[index];
            result.DataOutLen = outlen_override orelse @intCast(response.len);
            @memcpy(buffer[0..@sizeOf(ConfigCmd)], std.mem.asBytes(&result));
            status_read_count += 1;
        } else if (opcode == read_op and sector == data_sector) {
            if (hdr.dxfer_direction != c.SG_DXFER_FROM_DEV or hdr.dxfer_len != response.len) complaints += 1;
            const n = @min(hdr.dxfer_len, response.len);
            @memcpy(buffer[0..n], response[0..n]);
        } else {
            complaints += 1;
            return -1;
        }
        return 0;
    }
} else struct {};

fn testIntf() Intf {
    var intf: Intf = std.mem.zeroes(Intf);
    intf.fd = -1;
    return intf;
}

test "USB vtable matches C and closes its descriptor" {
    ModelDevice.reset();
    try std.testing.expectEqualStrings("usb", std.mem.sliceTo(&usb_intf.name, 0));
    try std.testing.expectEqualStrings("IPMI USB Interface(OEM Interface for AMI Devices)", std.mem.sliceTo(&usb_intf.desc, 0));
    try std.testing.expect(usb_intf.setup == setup);
    try std.testing.expect(usb_intf.sendrecv == sendrecv);
    var intf = testIntf();
    try std.testing.expectEqual(@as(c_int, 0), setup(&intf));
    try std.testing.expectEqual(@as(c_int, 1), intf.opened);
    close(&intf);
    close(&intf);
    try std.testing.expectEqual(@as(usize, 1), ModelDevice.close_count);
    try std.testing.expectEqual(@as(c_int, -1), intf.fd);
    try std.testing.expectEqual(@as(c_int, 0), intf.opened);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "probe scans AMI vendor lines, limits results, and closes proc stream" {
    ModelDevice.reset();
    ModelDevice.lines = &.{ "NOTAMI text\n", "\n", "AMI first\n", "AMI second\n", "AMI third\n" };
    var found: [2]c_int = .{ -1, -1 };
    var count: c_int = found.len;
    try std.testing.expectEqual(@as(c_int, 0), scsiProbeNew(&count, &found));
    try std.testing.expectEqual(@as(c_int, 2), count);
    try std.testing.expectEqualSlices(c_int, &.{ 1, 2 }, &found);
    try std.testing.expect(ModelDevice.file_closed);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "probe and setup report missing proc file and absent drives" {
    ModelDevice.reset();
    ModelDevice.file_available = false;
    var count: c_int = 16;
    var found: [16]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 1), scsiProbeNew(&count, &found));
    try std.testing.expectEqual(@as(c_int, 16), count);
    var intf = testIntf();
    try std.testing.expectEqual(@as(c_int, -1), setup(&intf));
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.open_count);
    ModelDevice.file_available = true;
    ModelDevice.lines = &.{"Other device\n"};
    try std.testing.expectEqual(@as(c_int, -1), setup(&intf));
    try std.testing.expect(ModelDevice.file_closed);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "discovery skips failed opens and wrong signatures without leaking descriptors" {
    ModelDevice.reset();
    ModelDevice.lines = &.{ "AMI first\n", "AMI second\n", "AMI third\n" };
    ModelDevice.fail_open = 0;
    ModelDevice.identify_number = 2;
    var intf = testIntf();
    try std.testing.expectEqual(@as(c_int, 0), setup(&intf));
    try std.testing.expectEqual(@as(usize, 3), ModelDevice.open_count);
    try std.testing.expectEqualStrings("/dev/sg0", std.mem.sliceTo(&ModelDevice.attempts[0], 0));
    try std.testing.expectEqualStrings("/dev/sg1", std.mem.sliceTo(&ModelDevice.attempts[1], 0));
    try std.testing.expectEqualStrings("/dev/sg2", std.mem.sliceTo(&ModelDevice.attempts[2], 0));
    try std.testing.expectEqual(@as(usize, 1), ModelDevice.close_count);
    try std.testing.expectEqual(@as(usize, 2), ModelDevice.lock_count);
    try std.testing.expectEqual(ModelDevice.lock_count, ModelDevice.unlock_count);
    try std.testing.expectEqual(@as(c_int, 202), intf.fd);
    close(&intf);
    try std.testing.expectEqual(@as(usize, 2), ModelDevice.close_count);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "all candidate drives failing identification are closed" {
    ModelDevice.reset();
    ModelDevice.lines = &.{ "AMI first\n", "AMI second\n" };
    ModelDevice.identify_number = 7;
    var intf = testIntf();
    try std.testing.expectEqual(@as(c_int, -1), setup(&intf));
    try std.testing.expectEqual(@as(c_int, -1), intf.fd);
    try std.testing.expectEqual(@as(c_int, 0), intf.opened);
    try std.testing.expectEqual(@as(usize, 2), ModelDevice.close_count);
    try std.testing.expectEqual(@as(usize, 2), ModelDevice.unlock_count);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "SCSI exchange encodes both sectors, polls, and strips completion code" {
    ModelDevice.reset();
    ModelDevice.statuses = &.{ in_process, 0, 0 };
    ModelDevice.response = &.{ 0, 0x41, 0x42 };
    var intf = testIntf();
    try std.testing.expectEqual(@as(c_int, 0), setup(&intf));
    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    var data = [_]u8{ 0xfa, 0x77 };
    req.msg.netfn_lun = .{ .netfn = 6, .lun = 2 };
    req.msg.cmd = 0x39;
    req.msg.data = &data;
    req.msg.data_len = data.len;
    const reply = sendrecv(&intf, &req).?;
    try std.testing.expectEqual(@as(u8, 0), reply.ccode);
    try std.testing.expectEqual(@as(c_int, 2), reply.data_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0x42 }, reply.data[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0x1a, 0x39, 0xfa, 0x77 }, ModelDevice.payload[0..ModelDevice.payload_len]);
    try std.testing.expectEqualSlices(u8, signature, &ModelDevice.header.BeginSig);
    try std.testing.expectEqual(@as(u32, 4), ModelDevice.header.DataInLen);
    try std.testing.expectEqual(@as(u32, ipmi.buf_size), ModelDevice.header.DataOutLen);
    try std.testing.expectEqual(@as(usize, 1), ModelDevice.sleeps);
    // Operation 0 is the identify, then header write, data write, status
    // polls, payload read and the post-read status verification.
    try std.testing.expectEqual(@as(usize, 7), ModelDevice.operation_count);
    const ops = ModelDevice.operations;
    try std.testing.expectEqual(ModelDevice.Operation{ .opcode = write_op, .sector = cmd_sector, .direction = c.SG_DXFER_TO_DEV, .len = @sizeOf(ConfigCmd), .timeout = 20000 }, ops[1]);
    try std.testing.expectEqual(ModelDevice.Operation{ .opcode = write_op, .sector = data_sector, .direction = c.SG_DXFER_TO_DEV, .len = 4, .timeout = 20000 }, ops[2]);
    try std.testing.expectEqual(ModelDevice.Operation{ .opcode = read_op, .sector = data_sector, .direction = c.SG_DXFER_FROM_DEV, .len = 3, .timeout = 5000 }, ops[5]);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "response length cannot exceed the advertised buffer" {
    ModelDevice.reset();
    ModelDevice.outlen_override = ipmi.buf_size + 1;
    var intf = testIntf();
    intf.fd = 200;
    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    const reply = sendrecv(&intf, &req).?;
    try std.testing.expectEqual(@as(u8, 0xff), reply.ccode);
    try std.testing.expectEqual(@as(c_int, 0), reply.data_len);
    try std.testing.expectEqual(@as(usize, 3), ModelDevice.status_read_count);
    for (ModelDevice.operations[0..ModelDevice.operation_count]) |op| {
        try std.testing.expect(op.opcode != read_op or op.sector != data_sector);
    }
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "the largest legal response stays within the IPMI buffer" {
    ModelDevice.reset();
    var bytes: [ipmi.buf_size]u8 = @splat(0x4b);
    bytes[0] = 0;
    ModelDevice.response = &bytes;
    var intf = testIntf();
    intf.fd = 200;
    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    const reply = sendrecv(&intf, &req).?;
    try std.testing.expectEqual(@as(u8, 0), reply.ccode);
    try std.testing.expectEqual(@as(c_int, ipmi.buf_size - 1), reply.data_len);
    try std.testing.expect(std.mem.allEqual(u8, reply.data[0 .. ipmi.buf_size - 1], 0x4b));
    try std.testing.expectEqual(@as(u8, 0), reply.data[ipmi.buf_size - 1]);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "nonzero completion codes retain the unshifted response" {
    ModelDevice.reset();
    ModelDevice.response = &.{ 0xc0, 0x99 };
    var intf = testIntf();
    intf.fd = 200;
    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    const reply = sendrecv(&intf, &req).?;
    try std.testing.expectEqual(@as(u8, 0xc0), reply.ccode);
    try std.testing.expectEqual(@as(c_int, 2), reply.data_len);
    try std.testing.expectEqualSlices(u8, &.{ 0xc0, 0x99 }, reply.data[0..2]);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "protocol errors retry whole transactions and return completion status" {
    ModelDevice.reset();
    ModelDevice.statuses = &.{3};
    var intf = testIntf();
    intf.fd = 200;
    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    const reply = sendrecv(&intf, &req).?;
    try std.testing.expectEqual(@as(u8, 3), reply.ccode);
    try std.testing.expectEqual(@as(c_int, 0), reply.data_len);
    try std.testing.expectEqual(@as(usize, 9), ModelDevice.operation_count);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "SG_IO retries two failed writes, then succeeds; permanent error fails" {
    ModelDevice.reset();
    ModelDevice.fail_opcode = write_op;
    ModelDevice.fail_sector = data_sector;
    ModelDevice.failures_left = 2;
    var intf = testIntf();
    intf.fd = 200;
    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    try std.testing.expectEqual(@as(u8, 0), sendrecv(&intf, &req).?.ccode);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.failures_left);
    ModelDevice.reset();
    ModelDevice.fail_opcode = write_op;
    ModelDevice.fail_sector = cmd_sector;
    ModelDevice.failures_left = 9;
    try std.testing.expectEqual(@as(u8, 0xff), sendrecv(&intf, &req).?.ccode);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.failures_left);
    try std.testing.expectEqual(@as(usize, 9), ModelDevice.operation_count);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "SG_IO bad info and short reads fail without exposing partial responses" {
    ModelDevice.reset();
    var intf = testIntf();
    intf.fd = 200;
    var request = [_]u8{ 0x18, 0x01 };
    var response: [8]u8 = @splat(0xa5);
    var len: c_int = response.len;
    ModelDevice.bad_info = true;
    try std.testing.expectEqual(@as(c_int, -1), sendData(&intf, &request, request.len, &response, &len, 100));
    try std.testing.expectEqual(@as(usize, 4), ModelDevice.operation_count);

    ModelDevice.reset();
    ModelDevice.short_read = true;
    len = response.len;
    try std.testing.expectEqual(@as(c_int, -1), sendData(&intf, &request, request.len, &response, &len, 100));
    try std.testing.expectEqual(@as(usize, 3), ModelDevice.status_read_count);
    try std.testing.expect(std.mem.allEqual(u8, &response, 0xa5));
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "data read failures are retried and returned as I/O errors" {
    ModelDevice.reset();
    ModelDevice.fail_opcode = read_op;
    ModelDevice.fail_sector = data_sector;
    ModelDevice.failures_left = 3;
    var intf = testIntf();
    intf.fd = 200;
    var request = [_]u8{ 0x18, 0x01 };
    var response: [8]u8 = @splat(0xa5);
    var len: c_int = response.len;
    try std.testing.expectEqual(@as(c_int, -1), sendData(&intf, &request, request.len, &response, &len, 100));
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.failures_left);
    try std.testing.expectEqual(@as(c_int, 8), len);
    try std.testing.expect(std.mem.allEqual(u8, &response, 0xa5));
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "the command-sector verification read is not silently ignored" {
    ModelDevice.reset();
    ModelDevice.fail_post_read = true;
    var intf = testIntf();
    intf.fd = 200;
    var request = [_]u8{ 0x18, 0x01 };
    var response: [8]u8 = @splat(0xa5);
    var len: c_int = response.len;
    try std.testing.expectEqual(@as(c_int, -1), sendData(&intf, &request, request.len, &response, &len, 100));
    try std.testing.expectEqual(@as(usize, 1), ModelDevice.status_read_count);
    try std.testing.expectEqual(@as(usize, 7), ModelDevice.operation_count);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "status polling observes the timeout; no-answer mode still writes data" {
    ModelDevice.reset();
    ModelDevice.statuses = &.{in_process};
    var intf = testIntf();
    intf.fd = 200;
    var req = [_]u8{ 0x18, 0x01 };
    var res: [8]u8 = @splat(0xa5);
    var len: c_int = res.len;
    try std.testing.expectEqual(@as(c_int, -2), sendData(&intf, &req, req.len, &res, &len, 2));
    try std.testing.expectEqual(@as(usize, 3), ModelDevice.sleeps);
    try std.testing.expectEqual(@as(usize, 3), ModelDevice.status_read_count);
    ModelDevice.reset();
    len = res.len;
    try std.testing.expectEqual(@as(c_int, 0), sendData(&intf, &req, req.len, &res, &len, 0));
    try std.testing.expectEqual(@as(c_int, res.len), len);
    try std.testing.expectEqual(@as(usize, 2), ModelDevice.operation_count);
    try std.testing.expectEqual(@as(u32, 3000), ModelDevice.operations[0].timeout);
    try std.testing.expectEqual(@as(u32, 20000), ModelDevice.operations[1].timeout);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}

test "invalid lengths fail before any SCSI call; empty reply cannot reuse previous response" {
    ModelDevice.reset();
    var intf = testIntf();
    intf.fd = 200;
    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    try std.testing.expectEqual(@as(u8, 0), sendrecv(&intf, &req).?.ccode);
    ModelDevice.response = &.{};
    const reply = sendrecv(&intf, &req).?;
    try std.testing.expectEqual(@as(u8, 0xff), reply.ccode);
    try std.testing.expectEqual(@as(c_int, 0), reply.data_len);
    const previous_count = ModelDevice.operation_count;
    req.msg.data_len = std.math.maxInt(u16);
    try std.testing.expectEqual(@as(u8, 0xff), sendrecv(&intf, &req).?.ccode);
    try std.testing.expectEqual(previous_count, ModelDevice.operation_count);
    var len: c_int = ipmi.buf_size + 1;
    var request = [_]u8{ 0x18, 0x01 };
    var response: [ipmi.buf_size]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, -1), sendData(&intf, &request, request.len, &response, &len, 100));
    try std.testing.expectEqual(previous_count, ModelDevice.operation_count);
    try std.testing.expectEqual(@as(usize, 0), ModelDevice.complaints);
}
