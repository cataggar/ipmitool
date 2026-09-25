//! Intel Manageability Engine firmware update commands (`lib/ipmi_ime.c`).
//! The C-facing entry point is selected with `-Dzig-modules=ime`.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");

const error_result: c_int = -1;
const restart_result: c_int = -2;
const chunk_size: usize = 22;
const status_size: usize = 13; // packed byte + 32-bit enum + 8 bytes
const caps_size: usize = 2;

const Status = struct {
    image_status: u8 = 0,
    update_state: i32 = 6, // IME_STATE_ABORTED on a failed status request
    update_attempt_status: u8 = 0,
    rollback_attempt_status: u8 = 0,
    update_type: u8 = 0,
    dependent_flag: u8 = 0,
    free_area_size: [4]u8 = .{ 0, 0, 0, 0 },
};

const Caps = struct {
    area_supported: u8 = 0,
    special_caps: u8 = 0,
};

fn send(intf: *Intf, netfn: u6, cmd: u8, data: ?[]u8) ?*ipmi.Response {
    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = netfn;
    req.msg.cmd = cmd;
    if (data) |bytes| {
        req.msg.data = bytes.ptr;
        req.msg.data_len = @intCast(bytes.len);
    }
    return intf.sendrecv.?(intf, &req);
}

fn checkedSend(intf: *Intf, netfn: u6, cmd: u8, data: ?[]u8, name: [*:0]const u8) ?*ipmi.Response {
    const rsp = send(intf, netfn, cmd, data) orelse {
        c.lprintf(log.Level.err, "%s command failed", name);
        return null;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "%s command failed: %s", name, c.val2str(rsp.ccode, c.completion_code_vals));
        return null;
    }
    return rsp;
}

fn getStatus(intf: *Intf, status: *Status) c_int {
    status.* = .{};
    const rsp = checkedSend(intf, 0x30, 0xa6, null, "UpdatePrepare") orelse return error_result;
    c.lprintf(log.Level.debug, "UpdatePrepare command succeed");
    if (rsp.data_len < status_size) {
        c.lprintf(log.Level.err, "UpdatePrepare command failed: short response");
        return error_result;
    }
    const b = rsp.data[0..status_size];
    status.* = .{
        .image_status = b[0],
        .update_state = @bitCast(std.mem.readInt(u32, b[1..5], .little)),
        .update_attempt_status = b[5],
        .rollback_attempt_status = b[6],
        .update_type = b[7],
        .dependent_flag = b[8],
        .free_area_size = b[9..13].*,
    };
    return 0;
}

fn getCapabilities(intf: *Intf, caps: *Caps) c_int {
    caps.* = .{};
    const rsp = checkedSend(intf, 0x30, 0xa7, null, "UpdatePrepare") orelse return error_result;
    c.lprintf(log.Level.debug, "UpdatePrepare command succeed");
    if (rsp.data_len < caps_size) {
        c.lprintf(log.Level.err, "UpdatePrepare command failed: short response");
        return error_result;
    }
    caps.* = .{ .area_supported = rsp.data[0], .special_caps = rsp.data[1] };
    return 0;
}

fn supported(bit: bool) [*:0]const u8 {
    return if (bit) "Supported" else "Unsupported";
}

fn valid(bit: bool) [*:0]const u8 {
    return if (bit) "Valid" else "Invalid";
}

fn getInfo(intf: *Intf) c_int {
    const rsp = checkedSend(intf, 0x06, 0x01, null, "Get Device ID") orelse return error_result;
    if (rsp.data_len < @sizeOf(c.struct_ipm_devid_rsp)) {
        c.lprintf(log.Level.err, "Get Device ID command failed: short response");
        return error_result;
    }
    const b = rsp.data[0..@sizeOf(c.struct_ipm_devid_rsp)];
    c.lprintf(log.Level.debug, "Device ID                 : %i", @as(c_int, b[0]));
    c.lprintf(log.Level.debug, "Device Revision           : %i", @as(c_int, b[1] & 0x0f));

    if (b[0] != 0 or (b[1] & 0x0f) != 0 or
        b[6] != 0x57 or b[7] != 0x01 or b[8] != 0x00 or
        b[9] != 0x00 or b[10] != 0x0b)
    {
        _ = c.printf("Supported ME not found\n");
        return error_result;
    }

    const manufacturer: c_uint = @as(c_uint, b[6]) | @as(c_uint, b[7]) << 8 | @as(c_uint, b[8]) << 16;
    const product_id: c_uint = @as(c_uint, b[9]) | @as(c_uint, b[10]) << 8;
    _ = c.printf("Manufacturer Name          : %s\n", c.val2str(manufacturer, c.ipmi_oem_info));
    _ = c.printf("Product ID                 : %u (0x%02x%02x)\n", product_id, @as(c_uint, b[10]), @as(c_uint, b[9]));
    const product = c.oemval2str(manufacturer, product_id, c.ipmi_oem_product_info);
    if (product != null) _ = c.printf("Product Name               : %s\n", product);
    _ = c.printf(
        "Intel ME Firmware Revision : %x.%02x.%02x.%x%x%x.%x\n",
        @as(c_uint, b[2] & 0x7f),
        @as(c_uint, b[3] >> 4),
        @as(c_uint, b[3] & 0x0f),
        @as(c_uint, b[12] >> 4),
        @as(c_uint, b[12] & 0x0f),
        @as(c_uint, b[13] >> 4),
        @as(c_uint, b[13] & 0x0f),
    );
    _ = c.printf("SPS FW IPMI cmd version    : %x.%x\n", @as(c_uint, b[11] >> 4), @as(c_uint, b[11] & 0x0f));
    c.lprintf(log.Level.debug, "Flags: %xh", @as(c_uint, b[14]));
    _ = c.printf("Current Image Type         : %s\n", @as([*:0]const u8, switch (b[14] & 3) {
        0 => "Recovery",
        1 => "Operational Image 1",
        2 => "Operational Image 2",
        else => "Unknown",
    }));

    var status: Status = .{};
    if (getStatus(intf, &status) != 0) return error_result;
    var caps: Caps = .{};
    if (getCapabilities(intf, &caps) != 0) return error_result;

    _ = c.printf("\nSupported Area\n");
    _ = c.printf("   Operation Code          : %s\n", supported((caps.area_supported & 2) != 0));
    _ = c.printf("   PIA                     : %s\n", supported((caps.area_supported & 4) != 0));
    _ = c.printf("   SDR                     : %s\n", supported((caps.area_supported & 8) != 0));
    _ = c.printf("\nSpecial Capabilities\n");
    _ = c.printf("   Rollback                : %s\n", supported((caps.special_caps & 1) != 0));
    _ = c.printf("   Recovery                : %s\n", supported((caps.special_caps & 2) != 0));
    _ = c.printf("\nImage Status\n");
    _ = c.printf("   Staging (new)           : %s\n", valid((status.image_status & 2) != 0));
    _ = c.printf("   Rollback                : %s\n", valid((status.image_status & 4) != 0));
    const run_area: c_uint = (status.image_status >> 3) & 3;
    if (run_area == 0) {
        _ = c.printf("   Running Image Area      : CODE\n");
    } else {
        _ = c.printf("   Running Image Area      : CODE%d\n", @as(c_int, @intCast(run_area)));
    }
    return 0;
}

fn prepare(intf: *Intf) c_int {
    _ = checkedSend(intf, 0x30, 0xa0, null, "UpdatePrepare") orelse return error_result;
    c.lprintf(log.Level.debug, "UpdatePrepare command succeed");
    return 0;
}

fn openArea(intf: *Intf) c_int {
    var data = [_]u8{ 1, 0 };
    _ = checkedSend(intf, 0x30, 0xa1, &data, "UpdateOpenArea") orelse return error_result;
    c.lprintf(log.Level.debug, "UpdateOpenArea command succeed");
    return 0;
}

fn writeArea(intf: *Intf, sequence: u8, bytes: []const u8) c_int {
    if (bytes.len > chunk_size) return error_result;
    var data: [chunk_size + 1]u8 = undefined;
    data[0] = sequence;
    @memcpy(data[1..][0..bytes.len], bytes);
    const rsp = send(intf, 0x30, 0xa2, data[0 .. bytes.len + 1]) orelse {
        c.lprintf(log.Level.err, "UpdateWriteArea command failed");
        return error_result;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "UpdateWriteArea command failed: %s", c.val2str(rsp.ccode, c.completion_code_vals));
        return if (rsp.ccode == 0x80) restart_result else error_result;
    }
    c.lprintf(log.Level.debug, "UpdateWriteArea command succeed");
    return 0;
}

fn closeArea(intf: *Intf, size: u32, checksum: u8) c_int {
    var data = [_]u8{
        @truncate(size),       @truncate(size >> 8), @truncate(size >> 16),
        @truncate(size >> 24), checksum,             0,
    };
    _ = checkedSend(intf, 0x30, 0xa3, &data, "UpdateCloseArea") orelse return error_result;
    c.lprintf(log.Level.debug, "UpdateCloseArea command succeed");
    return 0;
}

fn registerUpdate(intf: *Intf, update_type: u8) c_int {
    var data = [_]u8{ update_type, 0 };
    _ = checkedSend(intf, 0x30, 0xa4, &data, "ImeUpdateRegisterUpdate") orelse return error_result;
    c.lprintf(log.Level.debug, "ImeUpdateRegisterUpdate command succeed");
    return 0;
}

fn crc8(bytes: []const u8) u8 {
    var crc: u8 = 0;
    for (bytes) |b| {
        crc ^= b;
        for (0..8) |_| {
            crc = if ((crc & 0x80) != 0) (crc << 1) ^ 0x07 else crc << 1;
        }
    }
    return crc;
}

fn validImageSize(size: u64) bool {
    return size > 0 and size <= std.math.maxInt(u32);
}

fn imageFromFile(filename: [*:0]u8) ?[]u8 {
    const file = c.fopen(filename, "rb") orelse {
        c.lprintf(log.Level.notice, "Cannot open image file %s", filename);
        return null;
    };
    defer _ = c.fclose(file);
    if (c.fseek(file, 0, c.SEEK_END) != 0) {
        c.lprintf(log.Level.err, "Error seeking %s. %s\n", filename, c.strerror(std.c._errno().*));
        return null;
    }
    const end = c.ftell(file);
    if (end < 0) {
        c.lprintf(log.Level.err, "Error seeking %s. %s\n", filename, c.strerror(std.c._errno().*));
        return null;
    }
    if (!validImageSize(@intCast(end))) {
        if (end == 0) return null;
        c.lprintf(log.Level.err, "Image file %s exceeds maximum size", filename);
        return null;
    }
    const size: usize = @intCast(end);
    const memory = std.c.malloc(size) orelse return null;
    const bytes: [*]u8 = @ptrCast(memory);
    if (c.fseek(file, 0, c.SEEK_SET) != 0 or c.fread(bytes, 1, size, file) != size) {
        std.c.free(memory);
        return null;
    }
    return bytes[0..size];
}

fn upgrade(intf: *Intf, filename: [*:0]u8) c_int {
    const start = c.time(null);
    const image = imageFromFile(filename) orelse return error_result;
    defer std.c.free(image.ptr);
    const checksum = crc8(image);
    c.lprintf(log.Level.debug, "CRC8: %02xh\n", @as(c_uint, checksum));
    const size: u32 = @intCast(image.len);
    var status: Status = .{};
    // A failed initial status must not proceed with a firmware update.
    if (getStatus(intf, &status) != 0) return error_result;

    var rc = prepare(intf);
    if (getStatus(intf, &status) != 0 and rc == 0) rc = error_result;
    if (rc == 0 and status.update_state == 1) {
        rc = openArea(intf);
        if (getStatus(intf, &status) != 0 and rc == 0) rc = error_result;
    } else if (rc == 0) {
        c.lprintf(log.Level.@"error", "ME state error (%i), aborting", status.update_state);
        rc = error_result;
    }

    if (rc == 0 and status.update_state == 2) {
        var sequence: u8 = 0;
        var counter: usize = 0;
        var shown_percent: u8 = 0xff;
        while (counter < image.len and rc == 0) {
            const length = @min(chunk_size, image.len - counter);
            rc = writeArea(intf, sequence, image[counter..][0..length]);
            counter += length;
            sequence +%= 1;
            const current_percent: u8 = @intFromFloat(
                @as(f32, @floatFromInt(counter)) / @as(f32, @floatFromInt(image.len)) * 100.0,
            );
            if (current_percent != shown_percent) {
                shown_percent = current_percent;
                _ = c.printf("Percent: %02i,  ", @as(c_int, shown_percent));
                const elapsed = c.time(null) - start;
                _ = c.printf("Elapsed time %02ld:%02ld\r", @as(c_long, @intCast(@divTrunc(elapsed, 60))), @as(c_long, @intCast(@rem(elapsed, 60))));
                _ = c.fflush(c.stdout);
            }
        }
        if (getStatus(intf, &status) != 0 and rc == 0) rc = error_result;
        _ = c.printf("\n");
    } else if (rc == 0) {
        c.lprintf(log.Level.@"error", "ME state error (%i), aborting", status.update_state);
        rc = error_result;
    }

    if (rc == 0 and status.update_state == 2) {
        rc = closeArea(intf, size, checksum);
        if (getStatus(intf, &status) != 0 and rc == 0) rc = error_result;
    } else if (rc == 0) {
        c.lprintf(log.Level.@"error", "ME state error, aborting");
        rc = error_result;
    }

    if (rc == 0 and status.update_state == 1) {
        _ = c.printf("UpdateCompleted, Activate now\n");
        rc = registerUpdate(intf, 1);
        if (getStatus(intf, &status) != 0 and rc == 0) rc = error_result;
    } else if (rc == 0) {
        c.lprintf(log.Level.@"error", "ME state error, aborting");
        rc = error_result;
    }

    const elapsed = c.time(null) - start;
    if (rc == 0 and status.update_state == 3) {
        _ = c.printf("Update Completed in %02ld:%02ld\n", @as(c_long, @intCast(@divTrunc(elapsed, 60))), @as(c_long, @intCast(@rem(elapsed, 60))));
    } else {
        _ = c.printf("Update Error\n");
        _ = c.printf("\nTime Taken %02ld:%02ld\n", @as(c_long, @intCast(@divTrunc(elapsed, 60))), @as(c_long, @intCast(@rem(elapsed, 60))));
    }
    return rc;
}

fn manualRollback(intf: *Intf) c_int {
    const rc = registerUpdate(intf, 3);
    var status: Status = .{};
    const status_rc = getStatus(intf, &status);
    if (rc == 0 and status_rc == 0 and status.update_state == 5) {
        _ = c.printf("Manual Rollback Succeed\n");
        return 0;
    }
    _ = c.printf("Manual Rollback Completed With Error\n");
    return error_result;
}

fn usage() void {
    c.lprintf(log.Level.notice, "help                    - This help menu");
    c.lprintf(log.Level.notice, "info                    - Information about the present Intel ME");
    c.lprintf(log.Level.notice, "update <file>           - Upgrade the ME firmware from received image <file>");
    c.lprintf(log.Level.notice, "rollback                - Manual Rollback ME");
}

fn imeMain(intf: *Intf, argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    c.lprintf(log.Level.debug, "ipmi_ime_main()");
    if (argc <= 0 or std.mem.eql(u8, std.mem.span(argv[0]), "help")) {
        usage();
        return 0;
    }
    const command = std.mem.span(argv[0]);
    if (std.mem.eql(u8, command, "info")) return getInfo(intf);
    if (std.mem.eql(u8, command, "update")) {
        if (argc != 2) {
            c.lprintf(log.Level.@"error", "File must be provided with this option, see help\n");
            return error_result;
        }
        c.lprintf(log.Level.notice, "Update using file: %s", argv[1]);
        return upgrade(intf, argv[1]);
    }
    if (std.mem.eql(u8, command, "rollback")) return manualRollback(intf);
    usage();
    return 0;
}

pub fn exportSymbols() void {
    @setEvalBranchQuota(100_000);
    abi.assertCallSignature(@TypeOf(imeMain), @TypeOf(c.ipmi_ime_main));
    @export(&imeMain, .{ .name = "ipmi_ime_main", .linkage = .strong });
}

test "IME CRC8, image limits and write payload boundaries" {
    const full = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22 };
    try std.testing.expectEqual(@as(u8, 0x07), crc8(&.{0x01}));
    try std.testing.expectEqual(@as(u8, 0x28), crc8(&full));
    try std.testing.expectEqual(@as(u8, 0x2b), crc8(&full ++ .{0xff}));
    try std.testing.expect(!validImageSize(0));
    try std.testing.expect(validImageSize(std.math.maxInt(u32)));
    try std.testing.expect(!validImageSize(@as(u64, std.math.maxInt(u32)) + 1));
    var sequence: u8 = 255;
    sequence +%= 1;
    try std.testing.expectEqual(@as(u8, 0), sequence);
    try std.testing.expectEqual(@as(usize, 22), chunk_size);
    try std.testing.expectEqual(@as(usize, 13), status_size);
}
