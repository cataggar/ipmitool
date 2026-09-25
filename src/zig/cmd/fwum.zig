//! Kontron Firmware Update Manager commands, replacing lib/ipmi_fwum.c.
//! C's file-read loop expands `fileSize / MAX_BUFFER_SIZE` as
//! `(fileSize / 1024) * 16`; preserve its progress and 16 KiB reads, but
//! never construct the out-of-bounds pointers it passes to fread at EOF.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;

const err_level = c.LOG_ERR;
const image_limit = 512 * 1024;
const buffer_size = 16 * 1024;
const metadata_offset = 0x5a0;
const metadata_min_size = metadata_offset + 20;
const max_retry = 6;

var firm_buf: [image_limit]u8 = [_]u8{0} ** image_limit;
var save_fw_nfo: c.tKFWUM_SaveFirmwareInfo = std.mem.zeroes(c.tKFWUM_SaveFirmwareInfo);
var last_progress: c_ulong = std.math.maxInt(c_ulong);

const cmd_names = [_][*:0]const u8{
    "GetFwInfo",       "KickWatchdog",  "GetLastAnswer",  "BootHandshake",
    "ReportStatus",    "CtrlIPMBLine",  "SetFwState",     "GetFwStatus",
    "GetSpiMemStatus", "StartFwUpdate", "StartFwImage",   "SaveFwImage",
    "FinishFwImage",   "ReadFwImage",   "ManualRollback", "GetTraceLog",
};
const ext_cmd_names = [_][*:0]const u8{
    "FwUpgradeLock",  "ProcessFwUpg",   "ProcessFwRb",
    "WaitHSAfterUpg", "WaitFirstHSUpg", "FwInfoStateChange",
};
const state_names = [_][*:0]const u8{ "Invalid", "Begin", "Progress", "Completed" };
const bank_names = [_][*:0]const u8{
    "Not programmed",  "New firmware",  "Wait for validation",
    "Last Known Good", "Previous Good",
};
var exported_cmd_names = cmd_names;
var exported_ext_cmd_names = ext_cmd_names;
var exported_state_names = state_names;
const bank_state_vals = [_]c.struct_valstr{
    .{ .val = 0, .str = bank_names[0] },
    .{ .val = 1, .str = bank_names[1] },
    .{ .val = 2, .str = bank_names[2] },
    .{ .val = 3, .str = bank_names[3] },
    .{ .val = 4, .str = bank_names[4] },
};

fn isVerbose() bool {
    return c.verbose != 0;
}

fn intfName(intf: *Intf, name: []const u8) bool {
    return std.mem.indexOf(u8, std.mem.sliceTo(&intf.name, 0), name) != null;
}

fn send(intf: *Intf, netfn: u6, cmd: u8, body: []u8) ?*Response {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun = .{ .netfn = netfn, .lun = 0 };
    req.msg.cmd = cmd;
    req.msg.data_len = @intCast(body.len);
    req.msg.data = if (body.len == 0) null else body.ptr;
    return if (intf.sendrecv) |sendrecv| sendrecv(intf, &req) else null;
}

fn data(rsp: *const Response, required: usize, operation: [*:0]const u8) ?[]const u8 {
    if (rsp.data_len < 0 or @as(usize, @intCast(rsp.data_len)) < required or
        rsp.data_len > rsp.data.len)
    {
        c.lprintf(err_level, "Short FWUM %s response.", operation);
        return null;
    }
    return rsp.data[0..@intCast(rsp.data_len)];
}

fn wordBE(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

fn dwordBE(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) | bytes[3];
}

fn getFileSize(path: [*:0]const u8, size: *c_ulong) callconv(.c) c_int {
    const file = c.fopen(path, "rb") orelse return -1;
    defer _ = c.fclose(file);
    if (c.fseek(file, 0, c.SEEK_END) == 0) {
        const length = c.ftell(file);
        if (length > 0) size.* = @intCast(length);
    }
    return if (size.* != 0) 0 else -1;
}

fn showProgress(task: [*:0]const u8, current: c_ulong, total: c_ulong) callconv(.c) void {
    if (total == 0) return;
    const percent: f32 = @as(f32, @floatFromInt(current)) / @as(f32, @floatFromInt(total));
    const progress: c_ulong = @intFromFloat(@as(f32, 100) * percent);
    if (progress == last_progress) return;
    last_progress = progress;

    const hashes: usize = @min(@as(usize, @intFromFloat(percent * 42)), 42);
    var bar: [43]u8 = [_]u8{'#'} ** 43;
    bar[hashes] = 0;
    var blanks: [43]u8 = [_]u8{' '} ** 43;
    blanks[42 - hashes] = 0;
    _ = c.printf("%-25s : %s%s %3lu %%\r", task, &bar, &blanks, progress);
    if (progress == 100) _ = c.printf("\n");
    _ = c.fflush(null);
}

fn setupBuffers(path: [*:0]const u8, file_size: c_ulong) callconv(.c) c_int {
    if (file_size > image_limit) {
        c.lprintf(err_level, "FWUM firmware file exceeds 512 KiB.");
        return -1;
    }
    const file = c.fopen(path, "rb") orelse {
        c.lprintf(err_level, "Failed to open '%s' for reading.", path);
        return -1;
    };
    defer _ = c.fclose(file);
    @memset(&firm_buf, 0);

    // The C macro has no parentheses: division/modulus happen before "*16".
    const count: usize = @as(usize, @intCast(file_size / 1024)) * 16;
    const modulus: usize = @as(usize, @intCast(file_size % 1024)) * 16;
    var success = false;
    for (0..count) |chunk| {
        showProgress("Reading Firmware from File", @intCast(chunk), @intCast(count));
        const start = chunk * buffer_size;
        if (start <= image_limit - buffer_size and start < file_size and
            c.fread(&firm_buf[start], 1, buffer_size, file) == buffer_size)
            success = true;
    }
    const start = count * buffer_size;
    if (modulus > 0 and start < image_limit and modulus <= image_limit - start and
        c.fread(&firm_buf[start], 1, modulus, file) == modulus)
        success = true;
    if (success) showProgress("Reading Firmware from File", 100, 100);
    return if (success) 0 else -1;
}

fn checksumPadding(buffer: [*c]u8, size: c_ulong) callconv(.c) c_ushort {
    if (buffer == null or size > image_limit) return 0;
    var sum: u16 = 0;
    for (buffer[0..@intCast(size)]) |byte| sum +%= byte;
    return 0 -% sum;
}

fn getFirmwareInfo(buffer: [*c]u8, length: c_ulong, info: *c.tKFWUM_InFirmwareInfo) callconv(.c) c_int {
    if (buffer == null or length < metadata_min_size) return -1;
    const bytes = buffer[metadata_offset .. metadata_offset + 17];
    info.checksum = wordBE(bytes[4..6]);
    info.sumToRemoveFromChecksum = @as(c_ushort, bytes[4]) + bytes[5];
    info.fileSize = dwordBE(bytes[0..4]);
    info.boardId = wordBE(bytes[6..8]);
    info.deviceId = bytes[8];
    info.tableVers = bytes[9];
    info.implRev = bytes[10];
    info.versMajor = bytes[11] & 15;
    info.versMinor = bytes[12] >> 4;
    info.versSubMinor = bytes[12] & 15;
    info.sdrRev = bytes[13];
    info.iana = @as(c_uint, bytes[14]) |
        (@as(c_uint, bytes[15]) << 8) | (@as(c_uint, bytes[16]) << 16);
    fixTableVersion(info);
    return 0;
}

fn fixTableVersion(info: *c.tKFWUM_InFirmwareInfo) callconv(.c) void {
    if (info.boardId == 0) info.tableVers = 0xff;
}

fn getDeviceInfo(intf: *Intf, output: u8, board: *c.tKFWUM_BoardInfo) callconv(.c) c_int {
    const rsp = send(intf, ipmi.NetFn.app, 0x01, &.{}) orelse {
        c.lprintf(err_level, "Error in Get Device Id Command");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(err_level, "Get Device Id returned %x", @as(c_uint, rsp.ccode));
        return -1;
    }
    const bytes = data(rsp, 11, "Get Device Id") orelse return -1;
    board.iana = @as(c_uint, bytes[6]) |
        (@as(c_uint, bytes[7]) << 8) | (@as(c_uint, bytes[8]) << 16);
    board.boardId = @as(c_uint, bytes[9]) | (@as(c_uint, bytes[10]) << 8);
    if (output != 0) {
        if (board.iana == c.IPMI_OEM_KONTRON and
            board.boardId == c.KFWUM_BOARD_KONTRON_5002 and bytes.len < 12)
        {
            c.lprintf(err_level, "Short FWUM Get Device Id response.");
            return -1;
        }
        _ = c.printf("\nIPMC Info\n=========\n");
        _ = c.printf("Manufacturer Id           : %u\n", board.iana);
        _ = c.printf("Board Id                  : %u\n", board.boardId);
        _ = c.printf("Firmware Revision         : %u.%u%u", @as(c_uint, bytes[2]), @as(c_uint, bytes[3] >> 4), @as(c_uint, bytes[3] & 15));
        if (board.iana == c.IPMI_OEM_KONTRON and
            board.boardId == c.KFWUM_BOARD_KONTRON_5002)
            _ = c.printf(" SDR %u", @as(c_uint, bytes[11]));
        _ = c.printf("\n");
    }
    return 0;
}

fn getInfo(intf: *Intf, output: u8, banks: *u8) callconv(.c) c_int {
    const rsp = send(intf, ipmi.NetFn.firmware, 0, &.{}) orelse {
        c.lprintf(err_level, "Error in FWUM Firmware Get Info Command.");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(err_level, "FWUM Firmware Get Info returned %x", @as(c_uint, rsp.ccode));
        return -1;
    }
    const bytes = data(rsp, 6, "Get Info") orelse return -1;
    banks.* = bytes[5];
    if (output != 0) {
        _ = c.printf("\nFWUM info\n=========\n");
        _ = c.printf("Protocol Revision         : %02Xh\n", @as(c_uint, bytes[0]));
        _ = c.printf("Controller Device Id      : %02Xh\n", @as(c_uint, bytes[1]));
        _ = c.printf("Firmware Revision         : %u.%u%u", @as(c_uint, bytes[3]), @as(c_uint, bytes[4] >> 4), @as(c_uint, bytes[4] & 15));
        _ = c.printf(if ((bytes[2] & 1) != 0) " - DEBUG BUILD\n" else "\n");
        _ = c.printf("Number Of Memory Bank     : %u\n", @as(c_uint, banks.*));
    }
    if (bytes[0] <= 5 or bytes.len < 7) {
        save_fw_nfo.downloadType = c.KFWUM_DOWNLOAD_TYPE_ADDRESS;
        save_fw_nfo.bufferSize = 32;
        save_fw_nfo.overheadSize = 6;
        if (isVerbose()) _ = c.printf("Protocol Revision          : <= 5 detected, adjusting buffers\n");
    } else {
        save_fw_nfo.downloadType = c.KFWUM_DOWNLOAD_TYPE_SEQUENCE;
        save_fw_nfo.overheadSize = 4;
        if (isVerbose()) _ = c.printf("Protocol Revision          : > 5 optimizing buffers\n");
        save_fw_nfo.bufferSize = 32;
        if (isVerbose()) {
            if (intfName(intf, "lan")) {
                _ = c.printf("IOL payload size           : %d\n", @as(c_int, save_fw_nfo.bufferSize));
            } else if (intfName(intf, "open") and intf.target_addr != ipmi.bmc_slave_addr and
                intf.target_addr != intf.my_addr)
            {
                _ = c.printf("IPMB payload size          : %d\n", @as(c_int, save_fw_nfo.bufferSize));
            } else {
                _ = c.printf("SMI payload size           : %d\n", @as(c_int, save_fw_nfo.bufferSize));
            }
        }
    }
    return 0;
}

fn getStatus(intf: *Intf) callconv(.c) c_int {
    if (isVerbose()) _ = c.printf(" Getting Status!\n");
    var banks: u8 = 0;
    var result = getInfo(intf, 0, &banks);
    for (0..banks) |bank| {
        if (result != 0) break;
        var index = [_]u8{@intCast(bank)};
        const rsp = send(intf, ipmi.NetFn.firmware, 7, &index) orelse {
            c.lprintf(err_level, "Error in FWUM Firmware Get Status Command.");
            result = -1;
            break;
        };
        if (rsp.ccode != 0) {
            c.lprintf(err_level, "FWUM Firmware Get Status returned %x", @as(c_uint, rsp.ccode));
            result = -1;
            break;
        }
        const bytes = data(rsp, 1, "Get Status") orelse {
            result = -1;
            break;
        };
        const state: [*:0]const u8 = if (bytes[0] < bank_names.len)
            bank_names[bytes[0]]
        else
            "Unknown";
        _ = c.printf("\nBank State %d               : %s\n", @as(c_int, @intCast(bank)), state);
        if (bytes[0] == 0) continue;
        if (bytes.len < 7) {
            c.lprintf(err_level, "Short FWUM Get Status response.");
            result = -1;
            break;
        }
        const length = (@as(c_long, bytes[3]) << 16) | (@as(c_long, bytes[2]) << 8) | bytes[1];
        _ = c.printf("Firmware Length            : %ld bytes\n", length);
        _ = c.printf("Firmware Revision          : %u.%u%u SDR %u\n", @as(c_uint, bytes[4]), @as(c_uint, bytes[5] >> 4), @as(c_uint, bytes[5] & 15), @as(c_uint, bytes[6]));
    }
    _ = c.printf("\n");
    return result;
}

fn rollback(intf: *Intf) callconv(.c) c_int {
    var body = [_]u8{0};
    const rsp = send(intf, ipmi.NetFn.firmware, 0x0e, &body) orelse {
        c.lprintf(err_level, "Error in FWUM Manual Rollback Command.");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(err_level, "Error in FWUM Manual Rollback Command returned %x", @as(c_uint, rsp.ccode));
        return -1;
    }
    _ = c.printf("FWUM Starting Manual Rollback \n");
    return 0;
}

fn startImage(intf: *Intf, length: c_ulong, padding: c_ushort) callconv(.c) c_int {
    var body = [_]u8{
        @truncate(length),  @truncate(length >> 8),  @truncate(length >> 16),
        @truncate(padding), @truncate(padding >> 8), 1,
    };
    const bytes = body[0..if (save_fw_nfo.downloadType == c.KFWUM_DOWNLOAD_TYPE_ADDRESS) 5 else 6];
    const rsp = send(intf, ipmi.NetFn.firmware, 0x0a, bytes) orelse {
        c.lprintf(err_level, "Error in FWUM Firmware Start Firmware Image Download Command.");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(err_level, "FWUM Firmware Start Firmware Image Download returned %x", @as(c_uint, rsp.ccode));
        return -1;
    }
    const bank = data(rsp, 1, "Start Firmware Image") orelse return -1;
    _ = c.printf("Bank holding new firmware  : %d\n", @as(c_int, bank[0]));
    _ = c.sleep(5);
    return 0;
}

fn saveImage(intf: *Intf, sequence: u8, address: c_ulong, buffer: [*c]u8, length: *u8) callconv(.c) c_int {
    if (buffer == null or length.* > 28) return -1;
    var retry: bool = false;
    var no_response: u8 = 0;
    var attempts: usize = 0;
    while (attempts < 32) : (attempts += 1) {
        var body: [32]u8 = undefined;
        const header: usize = if (save_fw_nfo.downloadType == c.KFWUM_DOWNLOAD_TYPE_ADDRESS) 4 else 1;
        if (header == 4) {
            body[0] = @truncate(address);
            body[1] = @truncate(address >> 8);
            body[2] = @truncate(address >> 16);
            body[3] = length.*;
        } else body[0] = sequence;
        @memcpy(body[header..][0..length.*], buffer[0..length.*]);
        const rsp = send(intf, ipmi.NetFn.firmware, 0x0b, body[0 .. header + length.*]) orelse {
            c.lprintf(err_level, "Error in FWUM Firmware Save Firmware Image Download Command.");
            if (intfName(intf, "lan")) {
                no_response += 1;
                if (no_response < 6 and length.* > 1) {
                    length.* -= 1;
                    continue;
                }
                c.lprintf(err_level, "Error, too many commands without response.");
                length.* = 0;
                return -1;
            }
            // The C loop retries non-LAN timeouts forever. Bound it as well.
            continue;
        };
        switch (rsp.ccode) {
            0, 0x82 => return 0,
            0xc0 => {
                _ = c.sleep(1);
                continue;
            },
            0xc7 => {
                if (length.* <= 1) {
                    length.* = 0;
                    return -1;
                }
                length.* -= 1;
                retry = true;
            },
            0xc3 => {
                if (sequence == 0) {
                    if (length.* <= 1) {
                        length.* = 0;
                        return -1;
                    }
                    length.* -= 1;
                    retry = true;
                } else if (!retry) {
                    retry = true;
                } else return -1;
            },
            0x83 => {
                if (!retry) retry = true else return -1;
            },
            0xcf => retry = true,
            else => {
                c.lprintf(err_level, "FWUM Firmware Save Firmware Image Download returned %x", @as(c_uint, rsp.ccode));
                return -1;
            },
        }
    }
    c.lprintf(err_level, "Error, too many FWUM Save Firmware Image retries.");
    return -1;
}

fn finishImage(intf: *Intf, info: c.tKFWUM_InFirmwareInfo) callconv(.c) c_int {
    var body = [_]u8{
        info.versMajor, (info.versMinor << 4) | info.versSubMinor, info.sdrRev, 0,
    };
    for (0..max_retry) |_| {
        const rsp = send(intf, ipmi.NetFn.firmware, 0x0c, &body) orelse continue;
        if (rsp.ccode == 0xc0) continue;
        if (rsp.ccode != 0) {
            c.lprintf(err_level, "FWUM Firmware Finish Firmware Image Download returned %x", @as(c_uint, rsp.ccode));
            return -1;
        }
        return 0;
    }
    c.lprintf(err_level, "Error, too many FWUM Finish Firmware Image retries.");
    return -1;
}

fn upload(intf: *Intf, buffer: [*c]u8, total: c_ulong) callconv(.c) c_int {
    if (buffer == null or total == 0 or total > image_limit) return -1;
    var address: usize = 0;
    var last_address: usize = 0;
    var sequence: u8 = 0;
    var retry: usize = max_retry;
    while (address < total) {
        if (save_fw_nfo.bufferSize <= save_fw_nfo.overheadSize) return -1;
        var size: u8 = save_fw_nfo.bufferSize - save_fw_nfo.overheadSize;
        const remaining: usize = @intCast(total - address);
        size = @intCast(@min(@as(usize, size), remaining));
        size = @intCast(@min(@as(usize, size), 256 - address % 256));
        const old_size = size;
        const rc = saveImage(intf, sequence, @intCast(address), buffer + address, &size);
        if (rc != 0 and retry > 0) {
            retry -= 1;
            address = last_address;
        } else if (rc != 0 or size == 0) {
            return -1;
        } else {
            if (size != old_size) {
                _ = c.printf("Adjusting length to %d bytes \n", @as(c_int, size));
                save_fw_nfo.bufferSize -= old_size - size;
            }
            retry = max_retry;
            last_address = address;
            address += size;
        }
        if (address % 1024 == 0) showProgress("Writing Firmware in Flash", @intCast(address), total);
        sequence +%= 1;
    }
    showProgress("Writing Firmware in Flash", 100, 100);
    return 0;
}

fn startUpgrade(intf: *Intf) callconv(.c) c_int {
    var body = [_]u8{0};
    const rsp = send(intf, ipmi.NetFn.firmware, 9, &body) orelse {
        c.lprintf(err_level, "Error in FWUM Firmware Start Firmware Upgrade Command");
        return -1;
    };
    if (rsp.ccode != 0) {
        if (rsp.ccode == 0xd5)
            c.lprintf(err_level, "No firmware available for upgrade.  Download Firmware first.")
        else
            c.lprintf(err_level, "FWUM Firmware Start Firmware Upgrade returned %x", @as(c_uint, rsp.ccode));
        return -1;
    }
    return 0;
}

fn traceLog(intf: *Intf) callconv(.c) c_int {
    if (isVerbose()) _ = c.printf(" Getting Trace Log!\n");
    var result: c_int = 0;
    for (0..7) |chunk| {
        var index = [_]u8{@intCast(chunk)};
        const rsp = send(intf, ipmi.NetFn.firmware, 0x0f, &index) orelse {
            c.lprintf(err_level, "Error in FWUM Firmware Get Trace Log Command");
            result = -1;
            break;
        };
        if (rsp.ccode != 0) {
            c.lprintf(err_level, "FWUM Firmware Get Trace Log returned %x", @as(c_uint, rsp.ccode));
            result = -1;
            break;
        }
        const bytes = data(rsp, 21, "Get Trace Log") orelse {
            result = -1;
            break;
        };
        for (0..7) |entry| {
            const id = bytes[entry * 3];
            const state = bytes[entry * 3 + 1];
            if (state == 0) continue;
            if (state >= state_names.len) continue;
            const name: [*:0]const u8 = if (id < cmd_names.len)
                cmd_names[id]
            else if (id >= 0xc0 and id - 0xc0 < ext_cmd_names.len)
                ext_cmd_names[id - 0xc0]
            else
                continue;
            _ = c.printf("  Cmd ID: %17s -- CmdState: %10s -- CompCode: %2x\n", name, state_names[state], @as(c_uint, bytes[entry * 3 + 2]));
        }
    }
    _ = c.printf("\n");
    return result;
}

fn compatible(board: c.tKFWUM_BoardInfo, info: c.tKFWUM_InFirmwareInfo) callconv(.c) c_int {
    var result: c_int = 0;
    if (board.iana != info.iana) {
        c.lprintf(err_level, "Board IANA does not match firmware IANA.");
        result = -1;
    }
    if (board.boardId != info.boardId) {
        c.lprintf(err_level, "Board IANA does not match firmware IANA.");
        result = -1;
    }
    if (result != 0) c.lprintf(err_level, "Firmware invalid for target board. Download of upgrade aborted.");
    return result;
}

fn printInfo(board: c.tKFWUM_BoardInfo, info: c.tKFWUM_InFirmwareInfo) callconv(.c) void {
    _ = c.printf("Target Board Id            : %u\n", board.boardId);
    _ = c.printf("Target IANA number         : %u\n", board.iana);
    _ = c.printf("File Size                  : %lu bytes\n", @as(c_ulong, info.fileSize));
    _ = c.printf("Firmware Version           : %d.%d%d SDR %d\n", @as(c_int, info.versMajor), @as(c_int, info.versMinor), @as(c_int, info.versSubMinor), @as(c_int, info.sdrRev));
}

fn fwupgrade(intf: *Intf, path: [*:0]u8, action: c_int) callconv(.c) c_int {
    var size: c_ulong = 0;
    if (getFileSize(path, &size) != 0 or setupBuffers(path, size) != 0) return -1;
    const padding = checksumPadding(&firm_buf, size);
    var info = std.mem.zeroes(c.tKFWUM_InFirmwareInfo);
    if (getFirmwareInfo(&firm_buf, size, &info) != 0) return -1;
    var board = std.mem.zeroes(c.tKFWUM_BoardInfo);
    if (getDeviceInfo(intf, 0, &board) != 0 or compatible(board, info) != 0) return -1;
    var banks: u8 = 0;
    if (getInfo(intf, 0, &banks) != 0) return -1;
    printInfo(board, info);
    if (startImage(intf, size, padding) != 0 or upload(intf, &firm_buf, size) != 0 or
        finishImage(intf, info) != 0 or getStatus(intf) != 0) return -1;
    if (action != 0 and startUpgrade(intf) != 0) return -1;
    return 0;
}

fn printHelp() callconv(.c) void {
    c.lprintf(c.LOG_NOTICE, "KFWUM Commands:  info status download upgrade rollback tracelog");
}

fn infoCommand(intf: *Intf) callconv(.c) c_int {
    if (isVerbose()) _ = c.printf("Getting Kontron FWUM Info\n");
    var board = std.mem.zeroes(c.tKFWUM_BoardInfo);
    var banks: u8 = 0;
    const device_result = getDeviceInfo(intf, 1, &board);
    const info_result = getInfo(intf, 1, &banks);
    return if (device_result == 0 and info_result == 0) 0 else -1;
}

fn statusCommand(intf: *Intf) callconv(.c) c_int {
    if (isVerbose()) _ = c.printf("Getting Kontron FWUM Status\n");
    return getStatus(intf);
}

fn main(intf: *Intf, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
    _ = c.printf("FWUM extension Version %d.%d\n", @as(c_int, 1), @as(c_int, 3));
    if (argc < 1 or argv == null) {
        c.lprintf(err_level, "Not enough parameters given.");
        printHelp();
        return -1;
    }
    const args = argv.?;
    const command = std.mem.span(args[0] orelse return -1);
    if (std.mem.eql(u8, command, "help")) {
        printHelp();
        return 0;
    }
    if (std.mem.eql(u8, command, "info")) return infoCommand(intf);
    if (std.mem.eql(u8, command, "status")) return statusCommand(intf);
    if (std.mem.eql(u8, command, "rollback")) return rollback(intf);
    if (std.mem.eql(u8, command, "tracelog")) return traceLog(intf);
    if (std.mem.eql(u8, command, "download")) {
        if (argc < 2 or args[1] == null or args[1].?[0] == 0) {
            c.lprintf(err_level, "Path and file name must be specified.");
            return -1;
        }
        _ = c.printf("Firmware File Name         : %s\n", args[1].?);
        return fwupgrade(intf, args[1].?, 0);
    }
    if (std.mem.eql(u8, command, "upgrade")) {
        if (argc >= 2 and args[1] != null and args[1].?[0] != 0) {
            _ = c.printf("Upgrading using file name %s\n", args[1].?);
            return fwupgrade(intf, args[1].?, 1);
        }
        return startUpgrade(intf);
    }
    c.lprintf(err_level, "Invalid KFWUM command: %s", args[0].?);
    printHelp();
    return -1;
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(main), @TypeOf(c.ipmi_fwum_main));
    @export(&main, .{ .name = "ipmi_fwum_main" });
    @export(&infoCommand, .{ .name = "ipmi_fwum_info" });
    @export(&statusCommand, .{ .name = "ipmi_fwum_status" });
    @export(&fwupgrade, .{ .name = "ipmi_fwum_fwupgrade" });
    @export(&printHelp, .{ .name = "printf_kfwum_help" });
    @export(&printInfo, .{ .name = "printf_kfwum_info" });
    @export(&getFileSize, .{ .name = "KfwumGetFileSize" });
    @export(&setupBuffers, .{ .name = "KfwumSetupBuffersFromFile" });
    @export(&showProgress, .{ .name = "KfwumShowProgress" });
    @export(&checksumPadding, .{ .name = "KfwumCalculateChecksumPadding" });
    @export(&getFirmwareInfo, .{ .name = "KfwumGetInfoFromFirmware" });
    @export(&fixTableVersion, .{ .name = "KfwumFixTableVersionForOldFirmware" });
    @export(&getDeviceInfo, .{ .name = "KfwumGetDeviceInfo" });
    @export(&getInfo, .{ .name = "KfwumGetInfo" });
    @export(&getStatus, .{ .name = "KfwumGetStatus" });
    @export(&rollback, .{ .name = "KfwumManualRollback" });
    @export(&startImage, .{ .name = "KfwumStartFirmwareImage" });
    @export(&saveImage, .{ .name = "KfwumSaveFirmwareImage" });
    @export(&finishImage, .{ .name = "KfwumFinishFirmwareImage" });
    @export(&upload, .{ .name = "KfwumUploadFirmware" });
    @export(&startUpgrade, .{ .name = "KfwumStartFirmwareUpgrade" });
    @export(&traceLog, .{ .name = "KfwumGetTraceLog" });
    @export(&compatible, .{ .name = "ipmi_kfwum_checkfwcompat" });
    @export(&firm_buf, .{ .name = "firmBuf" });
    @export(&save_fw_nfo, .{ .name = "save_fw_nfo" });
    @export(&exported_cmd_names, .{ .name = "CMD_ID_STRING" });
    @export(&exported_ext_cmd_names, .{ .name = "EXT_CMD_ID_STRING" });
    @export(&exported_state_names, .{ .name = "CMD_STATE_STRING" });
    @export(&bank_state_vals, .{ .name = "bankStateValS" });
}

test "network failures have bounded retries and leave no image running" {
    c.log_init(null, 0, -100);
    defer c.log_halt();
    const Mock = struct {
        var calls: usize = 0;
        fn noReply(_: *Intf, _: *Request) callconv(.c) ?*Response {
            calls += 1;
            return null;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Mock.noReply;
    @memcpy(intf.name[0..5], "dummy");
    var image = [_]u8{0xa5} ** 28;
    var length: u8 = 28;
    try std.testing.expectEqual(@as(c_int, -1), saveImage(&intf, 0, 0, &image, &length));
    try std.testing.expectEqual(@as(usize, 32), Mock.calls);

    const info = std.mem.zeroes(c.tKFWUM_InFirmwareInfo);
    try std.testing.expectEqual(@as(c_int, -1), finishImage(&intf, info));
    try std.testing.expectEqual(@as(usize, 32 + max_retry), Mock.calls);

    @memcpy(intf.name[0..3], "lan");
    intf.name[3] = 0;
    length = 28;
    try std.testing.expectEqual(@as(c_int, -1), saveImage(&intf, 0, 0, &image, &length));
    try std.testing.expectEqual(@as(u8, 0), length);
    try std.testing.expectEqual(@as(usize, 32 + max_retry + 6), Mock.calls);
}

test "firmware metadata bounds, byte order, and old board version" {
    var image = [_]u8{0} ** metadata_min_size;
    var info = std.mem.zeroes(c.tKFWUM_InFirmwareInfo);
    try std.testing.expectEqual(@as(c_int, -1), getFirmwareInfo(&image, image.len - 1, &info));
    const bytes = image[metadata_offset..];
    bytes[0] = 0xf3;
    bytes[1] = 0xc2;
    bytes[2] = 0xb1;
    bytes[3] = 0x5a;
    bytes[6] = 0x13;
    bytes[7] = 0x8a;
    bytes[9] = 3;
    bytes[14] = 0xb1;
    bytes[15] = 0xc2;
    bytes[16] = 0xf3;
    try std.testing.expectEqual(@as(c_int, 0), getFirmwareInfo(&image, image.len, &info));
    try std.testing.expectEqual(@as(c_ulong, 0xf3c2b15a), info.fileSize);
    try std.testing.expectEqual(@as(c_uint, 0x138a), info.boardId);
    try std.testing.expectEqual(@as(c_uint, 0xf3c2b1), info.iana);
    bytes[6] = 0;
    bytes[7] = 0;
    try std.testing.expectEqual(@as(c_int, 0), getFirmwareInfo(&image, image.len, &info));
    try std.testing.expectEqual(@as(u8, 0xff), info.tableVers);
}

test "save-image completion-code retries and duplicate acceptance" {
    const Mock = struct {
        var replies: [2]u8 = .{ 0, 0 };
        var calls: usize = 0;
        var lengths: [2]u16 = .{ 0, 0 };
        var rsp: Response = std.mem.zeroes(Response);
        fn answer(_: *Intf, req: *Request) callconv(.c) ?*Response {
            const index = calls;
            calls += 1;
            lengths[index] = req.msg.data_len;
            rsp.ccode = replies[index];
            rsp.data_len = 0;
            return &rsp;
        }
    };
    const old = save_fw_nfo;
    defer save_fw_nfo = old;
    save_fw_nfo.downloadType = c.KFWUM_DOWNLOAD_TYPE_SEQUENCE;
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Mock.answer;
    var image = [_]u8{0x5a} ** 28;
    for ([_]u8{ 0x83, 0xcf, 0xc3 }) |first| {
        Mock.replies = .{ first, 0 };
        Mock.calls = 0;
        var length: u8 = 28;
        try std.testing.expectEqual(@as(c_int, 0), saveImage(&intf, 0, 0, &image, &length));
        try std.testing.expectEqual(@as(usize, 2), Mock.calls);
        try std.testing.expectEqual(@as(u16, 29), Mock.lengths[0]);
        try std.testing.expectEqual(@as(u16, if (first == 0xc3) 28 else 29), Mock.lengths[1]);
        try std.testing.expectEqual(@as(u8, if (first == 0xc3) 27 else 28), length);
    }
    Mock.replies = .{ 0x82, 0 };
    Mock.calls = 0;
    var length: u8 = 28;
    try std.testing.expectEqual(@as(c_int, 0), saveImage(&intf, 1, 28, &image, &length));
    try std.testing.expectEqual(@as(usize, 1), Mock.calls);

    Mock.replies = .{ 0x83, 0x83 };
    Mock.calls = 0;
    try std.testing.expectEqual(@as(c_int, -1), saveImage(&intf, 1, 28, &image, &length));
    try std.testing.expectEqual(@as(usize, 2), Mock.calls);
}
