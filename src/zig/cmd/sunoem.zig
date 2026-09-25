//! Sun/Oracle ILOM OEM commands (`lib/ipmi_sunoem.c`).
//! Kept as an optional link-time replacement; no C command implementation is
//! linked when `-Dzig-modules=sunoem` is selected.
const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;
const log = @import("../util/log.zig");

const Args = [*c][*c]u8;
const netfn: u6 = 0x2e;
const version_cmd: u8 = 0x24;
const tunnel_cmd: u8 = 0x44;

var ret_get: c_int = 0;
var ret_set: c_int = 0;

fn arg(argv: Args, n: usize) [*:0]u8 {
    return @ptrCast(argv[n]);
}
fn text(s: [*:0]const u8) []const u8 {
    return std.mem.span(s);
}
fn eql(s: [*:0]const u8, value: []const u8) bool {
    return std.mem.eql(u8, text(s), value);
}
fn ciEql(s: [*:0]const u8, value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text(s), value);
}
fn bytes(rsp: *Response) []const u8 {
    if (rsp.data_len <= 0) return &.{};
    return rsp.data[0..@min(@as(usize, @intCast(rsp.data_len)), rsp.data.len)];
}
fn send(intf: *Intf, cmd: u8, data: []u8) ?*Response {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn;
    req.msg.cmd = cmd;
    req.msg.data = if (data.len == 0) null else data.ptr;
    req.msg.data_len = @intCast(data.len);
    return intf.sendrecv.?(intf, &req);
}
fn ccString(ccode: u8) [*c]const u8 {
    return c.val2str(ccode, c.completion_code_vals);
}

fn usage() void {
    const lines = [_][*:0]const u8{
        "Usage: sunoem <command> [option...]",
        "",
        "Commands:",
        " - cli [<command string> ...]",
        "      Execute SP CLI commands.",
        "",
        " - led get [<sensor_id>] [ledtype]",
        "      - Read status of LED found in Generic Device Locator.",
        "",
        " - led set <sensor_id> <led_mode> [led_type]",
        "      - Set mode of LED found in Generic Device Locator.",
        "      - You can pass 'all' as the <senso_rid> to change the LED mode of all sensors.",
        "      - Use 'sdr list generic' command to get list of Generic",
        "      - Devices that are controllable LEDs.",
        "",
        "      - Required SIS LED Mode:",
        "          OFF          Off",
        "          ON           Steady On",
        "          STANDBY      100ms on 2900ms off blink rate",
        "          SLOW         1HZ blink rate",
        "          FAST         4HZ blink rate",
        "",
        "      - Optional SIS LED Type:",
        "          OK2RM        OK to Remove",
        "          SERVICE      Service Required",
        "          ACT          Activity",
        "          LOCATE       Locate",
        "",
        " - nacname <ipmi_nac_name>",
        "      - Returns the full nac name",
        "",
        " - ping NUMBER <q>",
        "      - Send and Receive NUMBER (64 Byte) packets.",
        "",
        "      - q - Quiet. Displays output at start and end",
        "",
        " - getval <target_name>",
        "      - Returns the ILOM property value",
        "",
        " - setval <property name> <property value> <timeout>",
        "      - Sets the ILOM property value",
        "      - If timeout is not specified, the default is 5 sec.",
        "      - NOTE: must be executed locally on host, not remotely over LAN!",
        "",
        " - sshkey del <user_id>",
        "      - Delete ssh key for user id from authorized_keys,",
        "      - view users with 'user list' command.",
        "",
        " - sshkey set <user_id> <id_rsa.pub>",
        "      - Set ssh key for a userid into authorized_keys,",
        "      - view users with 'user list' command.",
        "",
        " - version",
        "      - Display the software version",
        "",
        " - nacname <ipmi_nac_name>",
        "      - Returns the full nac name",
        "",
        " - getfile <file_string_id> <destination_file_name>",
        "      - Copy file <file_string_id> to <destination_file_name>",
        "",
        "      - File string ids:",
        "          SSH_PUBKEYS",
        "          DIAG_PASSED",
        "          DIAG_FAILED",
        "          DIAG_END_TIME",
        "          DIAG_INVENTORY",
        "          DIAG_TEST_LOG",
        "          DIAG_START_TIME",
        "          DIAG_UEFI_LOG",
        "          DIAG_TEST_LOG",
        "          DIAG_LAST_LOG",
        "          DIAG_LAST_CMD",
        "",
        " - getbehavior <behavior_string_id>",
        "      - Test if ILOM behavior is enabled",
        "",
        "      - Behavior string ids:",
        "          SUPPORTS_SIGNED_PACKAGES",
        "          REQUIRES_SIGNED_PACKAGES",
        "",
    };
    for (lines) |line| log.print(log.Level.notice, "%s", .{line});
}

fn getVersion(intf: *Intf) ?*Response {
    const rsp = send(intf, version_cmd, &.{}) orelse {
        log.print(log.Level.err, "Sun OEM Get SP Version Failed.", .{});
        return null;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Sun OEM Get SP Version Failed: %d", .{@as(c_int, rsp.ccode)});
        return null;
    }
    return rsp;
}
fn checkVersion(intf: *Intf) c_int {
    const rsp = getVersion(intf) orelse {
        log.print(log.Level.err, "Unable to get ILOM version", .{});
        return -1;
    };
    const data = bytes(rsp);
    if (data.len < 5) return -1;
    const required = [_]u8{ 3, 2, 0, 0 };
    for (required, 0..) |v, i| {
        const current = data[i + 1];
        if (current < v) return -@as(c_int, @intCast(i + 1));
        if (current > v) return @intCast(i + 1);
    }
    return 0;
}
fn version(intf: *Intf) c_int {
    const rsp = getVersion(intf) orelse return -1;
    const data = bytes(rsp);
    // The C struct is packed; its display version starts after five version
    // bytes, ten nano bytes and ten revision bytes.
    const v = if (data.len > 25) data[25..@min(data.len, 65)] else &.{};
    var display: [41]u8 = @splat(0);
    @memcpy(display[0..v.len], v);
    _ = c.printf("Version: %s\n", @as([*:0]const u8, @ptrCast(&display)));
    return 0;
}
fn nacname(intf: *Intf, name: [*:0]u8) c_int {
    const name_slice = text(name);
    if (name_slice.len > 16) {
        log.print(log.Level.err, "Sun OEM nacname command failed: Max size on IPMI name", .{});
        return -1;
    }
    var request: [65]u8 = @splat(0);
    @memcpy(request[1..][0..name_slice.len], name_slice);
    var full: [257]u8 = @splat(0);
    var total: usize = 0;
    var iterations: usize = 0;
    while (iterations < 256) : (iterations += 1) {
        const rsp = send(intf, 0x29, &request) orelse {
            log.print(log.Level.err, "Sun OEM nacname command failed.", .{});
            return -1;
        };
        if (rsp.ccode != 0) {
            log.print(log.Level.err, "Sun OEM nacname command failed: %d", .{@as(c_int, rsp.ccode)});
            return -1;
        }
        const reply = bytes(rsp);
        if (reply.len < 1) {
            log.print(log.Level.err, "Sun OEM nacname command failed.", .{});
            return -1;
        }
        const fragment = if (reply.len > 1) reply[1..@min(reply.len, 65)] else &.{};
        const len = std.mem.indexOfScalar(u8, fragment, 0) orelse fragment.len;
        if (len > 256 - total) {
            log.print(log.Level.err, "Sun OEM nacname command failed: invalid path length", .{});
            return -1;
        }
        @memcpy(full[total..][0..len], fragment[0..len]);
        total += len;
        if (reply[0] == request[0]) {
            _ = c.printf("NAC Name: %s\n", @as([*:0]const u8, @ptrCast(&full)));
            return 0;
        }
        request[0] = reply[0];
        if (@as(usize, request[0]) * 64 > 256) {
            log.print(log.Level.err, "Sun OEM nacname command failed: invalid path length", .{});
            return -1;
        }
    }
    log.print(log.Level.err, "Sun OEM nacname command failed: invalid path length", .{});
    return -1;
}

fn getval(intf: *Intf, path: [*:0]u8) c_int {
    if (text(path).len > 79) {
        log.print(log.Level.err, "Sun OEM get value command failed: Max size on IPMI name", .{});
        return -1;
    }
    const old = checkVersion(intf) < 0;
    if (old and eql(path, "/SP")) {
        path[1] = 'X';
        path[2] = 0;
    }
    var data: [80]u8 = @splat(0);
    @memcpy(data[1..][0..text(path).len], text(path));
    data[0] = 1;
    const start = send(intf, 0x2a, &data) orelse {
        log.print(log.Level.err, "Sun OEM getval1 command failed.", .{});
        return -1;
    };
    if (start.ccode != 0) {
        log.print(log.Level.err, "Sun OEM getval1 command failed: %d", .{@as(c_int, start.ccode)});
        return -1;
    }
    for (0..5) |_| {
        data[0] = 2;
        const rsp = send(intf, 0x2a, &data) orelse {
            log.print(log.Level.err, "Sun OEM getval2 command failed.", .{});
            return -1;
        };
        if (rsp.ccode != 0) {
            log.print(log.Level.err, "Sun OEM getval2 command failed: %d", .{@as(c_int, rsp.ccode)});
            return -1;
        }
        const result = bytes(rsp);
        if (result.len == 0) {
            log.print(log.Level.err, "Sun OEM getval2 command failed.", .{});
            return -1;
        }
        if (result[0] == 3) {
            var out: [80]u8 = @splat(0);
            const fragment = result[1..@min(result.len, 80)];
            @memcpy(out[0..fragment.len], fragment);
            _ = c.printf("Target Value: %s\n", @as([*:0]const u8, @ptrCast(&out)));
            return 0;
        }
        if (result[0] == 5) {
            log.print(log.Level.err, "Target: %s not found", .{path});
            return -1;
        }
        _ = c.sleep(1);
    }
    log.print(log.Level.err, "Unable to retrieve target value.", .{});
    return -1;
}

fn setvalPart(intf: *Intf, input: [*:0]u8, param: u8, tid: *u8) c_int {
    const src = text(input);
    var offset: usize = 0;
    while (offset < src.len) : (offset += 56) {
        var data: [60]u8 = @splat(0);
        data[0] = 3;
        data[1] = param;
        data[2] = tid.*;
        const n = @min(src.len - offset, 56);
        if (param == 1 and src.len - offset <= 56) data[3] = 1;
        @memcpy(data[4..][0..n], src[offset..][0..n]);
        const rsp = send(intf, 0x2c, &data) orelse {
            log.print(log.Level.err, if (param == 0) "Sun OEM setval prop name: response is NULL" else "Sun OEM setval prop value: response is NULL", .{});
            return -1;
        };
        if (rsp.ccode != 0) {
            if (param == 0)
                log.print(log.Level.err, "Sun OEM setval prop name: request failed: %d", .{@as(c_int, rsp.ccode)})
            else
                log.print(log.Level.err, "Sun OEM setval prop value: request failed: %d", .{@as(c_int, rsp.ccode)});
            return -1;
        }
        const result = bytes(rsp);
        if (result.len == 0 or result[0] != 1) {
            if (param == 0)
                log.print(log.Level.err, "Sun OEM setval prop name: invalid status code: %d", .{@as(c_int, if (result.len == 0) @as(u8, 0) else result[0])})
            else
                log.print(log.Level.err, "Sun OEM setval prop value: invalid status code: %d", .{@as(c_int, if (result.len == 0) @as(u8, 0) else result[0])});
            return -1;
        }
        if (param == 0 and result.len < 2) {
            log.print(log.Level.err, "Sun OEM setval prop name: invalid status code: %d", .{@as(c_int, result[0])});
            return -1;
        }
        if (param == 0 and result.len >= 2) tid.* = result[1];
    }
    return 0;
}
fn setval(intf: *Intf, name: [*:0]u8, value: [*:0]u8, timeout: ?[*:0]u8) c_int {
    if (text(name).len > 256) {
        log.print(log.Level.err, "Sun OEM set value command failed: Max size on property name", .{});
        return -1;
    }
    if (text(value).len > 1024) {
        log.print(log.Level.err, "Sun OEM set value command failed: Max size on property value", .{});
        return -1;
    }
    var retries: c_int = 5;
    if (timeout) |s| {
        if (c.str2int(s, &retries) != 0 or retries < 0) {
            log.print(log.Level.err, "Invalid input given or out of range for time-out parameter.", .{});
            return -1;
        }
    }
    var tid: u8 = 0;
    if (setvalPart(intf, name, 0, &tid) != 0 or setvalPart(intf, value, 1, &tid) != 0) return -1;
    var data: [60]u8 = @splat(0);
    data[0] = 4;
    data[2] = tid;
    var i: c_int = 0;
    while (i < retries) : (i += 1) {
        const rsp = send(intf, 0x2c, &data) orelse {
            log.print(log.Level.err, "Sun OEM setval command failed.", .{});
            return -1;
        };
        if (rsp.ccode != 0) {
            log.print(log.Level.err, "Sun OEM setval command failed: %d", .{@as(c_int, rsp.ccode)});
            return -1;
        }
        const result = bytes(rsp);
        if (result.len == 0 or result[0] == 3) {
            if (result.len == 0) return -1;
            _ = c.printf("Sun OEM setval command successful.\n");
            return 0;
        }
        if (result[0] != 4) {
            log.print(log.Level.err, "Sun OEM setval command failed.", .{});
            return -1;
        }
        _ = c.sleep(1);
    }
    log.print(log.Level.err, "Sun OEM setval command failed: Command Timed Out", .{});
    return -1;
}

const FileReplyError = error{ ShortReply, InvalidSize, IncorrectBlock };
fn fileBlock(reply: []const u8, requested_block: []const u8) FileReplyError![]const u8 {
    if (reply.len < 9) return error.ShortReply;
    const size = std.mem.readInt(u32, reply[4..8], .big);
    if (size > 1024 or @as(usize, size) > reply.len - 9) return error.InvalidSize;
    if (!std.mem.eql(u8, reply[0..4], requested_block)) return error.IncorrectBlock;
    return reply[9..][0..size];
}

fn getfile(intf: *Intf, file_id: [*:0]u8, destination: [*:0]u8) c_int {
    if (checkVersion(intf) < 0) {
        log.print(log.Level.err, "Command is not supported by this version of ILOM, required at least: 3.2.0.0", .{});
        return -1;
    }
    const id = text(file_id);
    if (id.len >= 1024) {
        log.print(log.Level.err, "File ID >= %d characters", .{@as(c_int, 16)});
        return -1;
    }
    var data: [21]u8 = @splat(0);
    @memcpy(data[1..][0..@min(id.len, 15)], id[0..@min(id.len, 15)]);
    data[0] = 11;
    const fp = c.ipmi_open_file_write(destination) orelse {
        log.print(log.Level.err, "Unable to open file: %s", .{destination});
        return -1;
    };
    defer _ = c.fclose(fp);
    var block: u32 = 0;
    while (true) {
        const be = std.mem.nativeToBig(u32, block);
        @memcpy(data[17..21], std.mem.asBytes(&be));
        const rsp = send(intf, tunnel_cmd, &data) orelse {
            log.print(log.Level.err, "Sun OEM getfile command failed.", .{});
            return -1;
        };
        if (rsp.ccode != 0) {
            log.print(log.Level.err, "Sun OEM getfile command failed: %d", .{@as(c_int, rsp.ccode)});
            return -1;
        }
        const reply = bytes(rsp);
        const block_data = fileBlock(reply, data[17..21]) catch |err| {
            switch (err) {
                error.ShortReply => log.print(log.Level.err, "Sun OEM getfile invalid data size: %d", .{@as(c_int, 0)}),
                error.InvalidSize => log.print(log.Level.err, "Sun OEM getfile invalid data size: %d", .{@as(c_int, @bitCast(std.mem.readInt(u32, reply[4..8], .big)))}),
                error.IncorrectBlock => {
                    log.print(log.Level.err, "Sun OEM getfile Incorrect Block Num Returned", .{});
                    log.print(log.Level.err, "Expecting: %x Received: %x", .{
                        @as(c_uint, std.mem.readInt(u32, data[17..21], .little)),
                        @as(c_uint, std.mem.readInt(u32, reply[0..4], .little)),
                    });
                },
            }
            return -1;
        };
        if (c.fwrite(block_data.ptr, 1, block_data.len, fp) != block_data.len) {
            log.print(log.Level.err, "Sun OEM getfile write failed: %d", .{@as(c_int, rsp.ccode)});
            return -1;
        }
        block +%= 1;
        if (reply[8] != 0) break;
    }
    return 0;
}
fn getbehavior(intf: *Intf, behavior: [*:0]u8) c_int {
    if (checkVersion(intf) < 0) {
        log.print(log.Level.err, "Command is not supported by this version of ILOM, required at least: 3.2.0.0", .{});
        return -1;
    }
    const id = text(behavior);
    if (id.len >= 32) {
        log.print(log.Level.err, "Behavior ID >= %d characters", .{@as(c_int, 32)});
        return -1;
    }
    var data: [33]u8 = @splat(0);
    data[0] = 15;
    @memcpy(data[1..][0..id.len], id);
    const rsp = send(intf, tunnel_cmd, &data) orelse {
        log.print(log.Level.err, "Sun OEM getbehavior command failed.", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Sun OEM getbehavior command failed: %d", .{@as(c_int, rsp.ccode)});
        return -1;
    }
    const reply = bytes(rsp);
    if (reply.len == 0) {
        log.print(log.Level.err, "Sun OEM getbehavior command failed.", .{});
        return -1;
    }
    _ = c.printf("ILOM behavior %s %s enabled\n", @as([*:0]const u8, @ptrCast(&data[1])), if (reply[0] != 0) @as([*:0]const u8, "is") else "is not");
    return 0;
}
fn sshDel(intf: *Intf, uid: u8) c_int {
    var data = [_]u8{uid};
    const rsp = send(intf, 0x02, &data) orelse {
        log.print(log.Level.err, "Unable to delete ssh key for UID %d", .{@as(c_int, uid)});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Unable to delete ssh key for UID %d: %s", .{ @as(c_int, uid), ccString(rsp.ccode) });
        return -1;
    }
    _ = c.printf("Deleted SSH key for user id %d\n", @as(c_int, uid));
    return 0;
}
fn sshSet(intf: *Intf, uid: u8, filename: [*:0]u8) c_int {
    const fp = c.ipmi_open_file_read(filename) orelse {
        log.print(log.Level.err, "Unable to open file '%s' for reading.", .{filename});
        return -1;
    };
    defer _ = c.fclose(fp);
    if (c.fseek(fp, 0, c.SEEK_END) != 0) {
        log.print(log.Level.err, "Failed to seek in file '%s'.", .{filename});
        return -1;
    }
    const size = c.ftell(fp);
    if (size < 0) {
        log.print(log.Level.err, "Failed to seek in file '%s'.", .{filename});
        return -1;
    }
    if (size == 0) {
        log.print(log.Level.err, "File '%s' is empty.", .{filename});
        return -1;
    }
    if (c.fseek(fp, 0, c.SEEK_SET) != 0) {
        log.print(log.Level.err, "Failed to seek in file '%s'.", .{filename});
        return -1;
    }
    _ = c.printf("Setting SSH key for user id %d...", @as(c_int, uid));
    var offset: c_long = 0;
    while (offset < size) {
        var data: [67]u8 = @splat(0);
        const count: usize = @intCast(@min(size - offset, 64));
        if (c.fseek(fp, offset, c.SEEK_SET) != 0 or c.fread(&data[3], 1, count, fp) != count) {
            _ = c.printf("failed\n");
            log.print(log.Level.err, "Unable to read %ld bytes from file '%s'.", .{ @as(c_long, @intCast(count)), filename });
            return -1;
        }
        _ = c.printf(".");
        _ = c.fflush(c.stdout);
        data[0] = uid;
        if (offset + 64 >= size) {
            data[1] = 0xff;
        } else {
            if (@divTrunc(offset, 64) > 255) {
                _ = c.printf("failed\n");
                log.print(log.Level.err, "Unable to pack byte %ld from file '%s'.", .{ @as(c_long, offset), filename });
                return -1;
            }
            data[1] = @intCast(@divTrunc(offset, 64));
        }
        data[2] = @intCast(count);
        const rsp = send(intf, 0x01, data[0 .. count + 3]) orelse {
            _ = c.printf("failed\n");
            log.print(log.Level.err, "Unable to set ssh key for UID %d.", .{@as(c_int, uid)});
            return -1;
        };
        if (rsp.ccode != 0) {
            _ = c.printf("failed\n");
            log.print(log.Level.err, "Unable to set ssh key for UID %d, %s.", .{ @as(c_int, uid), ccString(rsp.ccode) });
            return -1;
        }
        offset += @intCast(count);
    }
    _ = c.printf("done\n");
    return 0;
}
fn echo(intf: *Intf, argc: c_int, argv: Args) c_int {
    if (argc < 1) return 1;
    var quiet = false;
    if (argc == 2) {
        if (arg(argv, 1)[0] == 'q') {
            quiet = true;
        } else {
            log.print(log.Level.err, "Unknown option '%s' given.", .{arg(argv, 1)});
            return -1;
        }
    } else if (argc > 2) {
        log.print(log.Level.err, "Too many parameters given. See help for more information.", .{});
        return -1;
    }
    var count: u16 = 0;
    if (c.str2ushort(arg(argv, 0), &count) != 0) {
        log.print(log.Level.err, "Given number of packets is either invalid or out of range.", .{});
        return -1;
    }
    var data: [66]u8 = undefined;
    for (data[2..], 0..) |*b, i| b.* = @intCast(i);
    var received: c_int = 0;
    var transmitted: c_int = 0;
    var min: u32 = std.math.maxInt(c_int);
    var max: u32 = 0;
    var total: u32 = 0;
    var rc: c_int = 0;
    for (0..count) |i| {
        std.mem.writeInt(u16, data[0..2], @intCast(i), @import("builtin").cpu.arch.endian());
        transmitted += 1;
        var start: c.struct_timeval = undefined;
        var end: c.struct_timeval = undefined;
        _ = c.gettimeofday(&start, null);
        const rsp = send(intf, 0x23, &data);
        _ = c.gettimeofday(&end, null);
        const millis: u32 = @bitCast(@as(i32, @truncate((end.tv_sec - start.tv_sec) * 1000 + @divTrunc(end.tv_usec - start.tv_usec, 1000))));
        if (rsp == null or rsp.?.ccode != 0) {
            log.print(log.Level.err, "Sun OEM echo command failed. Seq # %d", .{@as(c_int, @intCast(i))});
            rc = -2;
            break;
        }
        const response = rsp.?;
        const reply = bytes(response);
        const sequence: u16 = if (reply.len >= 2) std.mem.readInt(u16, reply[0..2], @import("builtin").cpu.arch.endian()) else 0;
        if (sequence != i) {
            _ = c.printf("Invalid Seq # Expecting %d Received %d\n", @as(c_int, @intCast(i)), @as(c_int, sequence));
            rc = -2;
            break;
        }
        if (response.session.msglen == 66) {
            _ = c.printf("Invalid payload size for seq # %d. Expecting %d Received %d\n", @as(c_int, sequence), @as(c_int, 66), @as(c_int, response.session.msglen));
            rc = -2;
            break;
        }
        for (0..64) |j| {
            const actual: u8 = if (j + 2 < reply.len) reply[j + 2] else 0;
            if (actual != j) {
                _ = c.printf("Corrupt data packet. Seq # %d Offset %d\n", @as(c_int, sequence), @as(c_int, @intCast(j)));
                rc = -2;
                break;
            }
        }
        if (rc != 0) break;
        total +%= millis;
        min = @min(min, millis);
        max = @max(max, millis);
        received += 1;
        if (!quiet) _ = c.printf("Receive %lu Bytes - Seq. # %d time=%d ms\n", @as(c_ulong, 66), @as(c_int, sequence), @as(c_int, @bitCast(millis)));
    }
    _ = c.printf("%d packets transmitted, %d packets received\n", transmitted, received);
    if (received != 0) _ = c.printf("round-trip min/avg/max = %d/%d/%d ms\n", @as(c_int, @bitCast(min)), @as(c_int, @bitCast(total / @as(u32, @intCast(received)))), @as(c_int, @bitCast(max)));
    return rc;
}

const modes = [_]c.struct_valstr{
    .{ .val = 0, .str = "OFF" },
    .{ .val = 1, .str = "ON" },
    .{ .val = 2, .str = "STANDBY" },
    .{ .val = 3, .str = "SLOW" },
    .{ .val = 4, .str = "FAST" },
    .{ .val = 0xff, .str = null },
};
const alt_modes = [_]c.struct_valstr{
    .{ .val = 0, .str = "STEADY_OFF" },
    .{ .val = 1, .str = "STEADY_ON" },
    .{ .val = 2, .str = "STANDBY_BLINK" },
    .{ .val = 3, .str = "SLOW_BLINK" },
    .{ .val = 4, .str = "FAST_BLINK" },
    .{ .val = 0xff, .str = null },
};
const led_types = [_]c.struct_valstr{
    .{ .val = 0, .str = "OK2RM" },
    .{ .val = 1, .str = "SERVICE" },
    .{ .val = 2, .str = "ACT" },
    .{ .val = 3, .str = "LOCATE" },
    .{ .val = 0xff, .str = null },
};

// The C SDR list is pragma-packed, including the pointers in its union.
// The bridge's translated declaration drops that packing, so mirror it here.
const SdrList = extern struct {
    id: u16 align(1),
    version: u8,
    type: u8,
    length: u8,
    raw: ?[*]u8 align(1),
    next: ?*SdrList align(1),
    record: ?*anyopaque align(1),
};
const Entity = extern struct { id: u8, instance: u8 };
fn entityInstance(raw: u8) u8 {
    return raw & 0x7f;
}
fn entityLogical(raw: u8) bool {
    return raw & 0x80 != 0;
}
fn entityByte(instance: u8) u8 {
    return instance & 0x7f;
}
fn associationIsRange(flags: u8) bool {
    return flags & 0x80 != 0;
}
fn list(ptr: anytype) ?*SdrList {
    return if (ptr == null) null else @ptrCast(@alignCast(ptr));
}
fn freeList(head: ?*SdrList) void {
    var current = head;
    while (current) |node| {
        current = node.next;
        c.free(node);
    }
}
fn device(entry: *SdrList) ?[*]u8 {
    return if (entry.record) |r| @ptrCast(r) else null;
}
fn ledPrint(name: [*:0]const u8, mode: u8, valid: bool) void {
    const state = if (valid) c.val2str(mode, &modes) else @as([*c]const u8, "na");
    if (c.csv_output != 0) {
        _ = c.printf("%s,%s\n", name, state);
    } else {
        _ = c.printf("%-16s | %s\n", name, state);
    }
}
fn deviceName(dev: [*]const u8) [17:0]u8 {
    var out: [17:0]u8 = @splat(0);
    @memcpy(out[0..16], dev[11..27]);
    return out;
}
fn ledRequest(intf: *Intf, dev: [*]const u8, ledtype: u8, mode: ?u8) ?*Response {
    var data: [9]u8 = @splat(0);
    data[0] = dev[1];
    data[1] = if (ledtype == 0xff) dev[9] else ledtype;
    data[2] = dev[0];
    data[3] = dev[9];
    if (mode) |m| {
        data[4] = m;
        data[5] = dev[7];
        data[6] = entityInstance(dev[8]);
    } else {
        data[4] = dev[7];
        data[5] = entityInstance(dev[8]);
    }
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn;
    req.msg.netfn_lun.lun = @truncate(dev[2] >> 3);
    req.msg.cmd = if (mode != null) 0x22 else 0x21;
    req.msg.data = &data;
    req.msg.data_len = if (mode != null) 9 else 7;
    const rsp = intf.sendrecv.?(intf, &req);
    if (mode != null) {
        if (rsp == null) {
            log.print(log.Level.err, "Sun OEM Set LED command failed.", .{});
        } else if (rsp.?.ccode != 0) {
            log.print(log.Level.err, "Sun OEM Set LED command failed: %s", .{ccString(rsp.?.ccode)});
            return null;
        }
    }
    return rsp;
}
fn ledOne(intf: *Intf, dev: [*]const u8, type_id: u8, mode: ?u8, name: [*:0]const u8, grouped: bool) void {
    const rsp = ledRequest(intf, dev, type_id, mode);
    if (mode) |m| {
        if (rsp) |r| {
            if (!grouped or r.data_len == 0) ledPrint(name, m, true);
        } else {
            ret_set = -1;
        }
    } else {
        if (rsp) |r| {
            if (r.ccode == 0 and r.data_len == 1) {
                ledPrint(name, r.data[0], true);
                return;
            }
            if (r.ccode == 0xd3) {
                ledPrint(name, 0, false);
                return;
            }
        }
        ledPrint(name, 0, false);
        ret_get = -1;
    }
}
fn ledByEntity(intf: *Intf, id: u8, instance: u8, type_id: u8, mode: ?u8) void {
    if (id == 0) return;
    var entity = Entity{ .id = id, .instance = entityByte(instance) };
    const head = list(c.ipmi_sdr_find_sdr_byentity(@ptrCast(intf), @ptrCast(&entity)));
    if (head == null) {
        if (mode == null) ret_get = -1 else ret_set = -1;
    }
    defer freeList(head);
    var current = head;
    while (current) |entry| : (current = entry.next) {
        if (entry.type != 0x10) continue;
        const dev = device(entry) orelse continue;
        const name = deviceName(dev);
        ledOne(intf, dev, type_id, mode, &name, true);
    }
}
fn led(intf: *Intf, is_set: bool, argc: c_int, argv: Args) c_int {
    if (argc < (if (is_set) @as(c_int, 2) else 1) or eql(arg(argv, 0), "help")) {
        usage();
        return 0;
    }
    var mode: ?u8 = null;
    if (is_set) {
        var n = c.str2val32(arg(argv, 1), &modes);
        if (n == 0xff) n = c.str2val32(arg(argv, 1), &alt_modes);
        if (n == 0xff) {
            log.print(log.Level.notice, "Invalid LED Mode: %s", .{arg(argv, 1)});
            return -1;
        }
        mode = @intCast(n);
    }
    var type_id: u8 = 0xff;
    if (argc > (if (is_set) @as(c_int, 3) else 1)) {
        const pos: usize = if (is_set) 2 else 1;
        type_id = @truncate(c.str2val32(arg(argv, pos), &led_types));
        if (type_id == 0xff) log.print(log.Level.err, "Unknown ledtype, will use data from the SDR oem field", .{});
    }
    if (ciEql(arg(argv, 0), "all")) {
        const head = list(c.ipmi_sdr_find_sdr_bytype(@ptrCast(intf), 0x10));
        if (head == null) return -1;
        defer freeList(head);
        var current = head;
        while (current) |entry| : (current = entry.next) {
            if (entry.type != 0x10) continue;
            const dev = device(entry) orelse continue;
            if (entityLogical(dev[8])) continue;
            const name = deviceName(dev);
            if (is_set) {
                const rsp = ledRequest(intf, dev, type_id, mode);
                if (rsp != null and rsp.?.ccode == 0) ledPrint(&name, mode.?, true) else ret_set = -1;
            } else ledOne(intf, dev, type_id, null, &name, false);
        }
        return if ((if (is_set) ret_set else ret_get) == -1) -1 else 0;
    }
    const record = list(c.ipmi_sdr_find_sdr_byid(@ptrCast(intf), arg(argv, 0))) orelse {
        log.print(log.Level.err, "No Sensor Data Record found for %s", .{arg(argv, 0)});
        return -1;
    };
    if (record.type != 0x10) {
        log.print(log.Level.err, "Invalid SDR type %d", .{@as(c_int, record.type)});
        return -1;
    }
    const dev = device(record) orelse return -1;
    if (!entityLogical(dev[8])) {
        const name = deviceName(dev);
        ledOne(intf, dev, type_id, mode, if (is_set) arg(argv, 0) else &name, false);
        return if ((if (is_set) ret_set else ret_get) == -1) -1 else 0;
    }
    log.print(log.Level.info, "LED %s is logical device", .{arg(argv, 0)});
    const head = list(c.ipmi_sdr_find_sdr_bytype(@ptrCast(intf), 0x08)) orelse return -1;
    defer freeList(head);
    var current: ?*SdrList = head;
    while (current) |entry| : (current = entry.next) {
        if (entry.type != 0x08) continue;
        const assoc = device(entry) orelse continue;
        if (assoc[0] != dev[7] or entityInstance(assoc[1]) != entityInstance(dev[8])) continue;
        if (!associationIsRange(assoc[2])) {
            for (0..4) |i| ledByEntity(intf, assoc[3 + i * 2], assoc[4 + i * 2], type_id, mode);
        } else {
            for (0..2) |i| {
                const p = 3 + i * 4;
                if (assoc[p] != assoc[p + 2]) continue;
                var instance: usize = assoc[p + 1];
                while (instance <= assoc[p + 3]) : (instance += 1) ledByEntity(intf, assoc[p], @intCast(instance), type_id, mode);
            }
        }
    }
    return if ((if (is_set) ret_set else ret_get) == -1) -1 else 0;
}

var cli_version: u8 = 2;
fn cliMessage(reply: []const u8) [73:0]u8 {
    var value: [73:0]u8 = @splat(0);
    if (reply.len > 8) {
        const fragment = reply[8..@min(reply.len, 80)];
        @memcpy(value[0..fragment.len], fragment);
    }
    value[71] = 0;
    return value;
}
fn cli(intf: *Intf, original_count: c_int, original_argv: Args) c_int {
    var argc = original_count;
    var argv = original_argv;
    var request: [80]u8 = @splat(0);
    request[0] = cli_version;
    if (argc > 0 and eql(arg(argv, 0), "force")) {
        request[1] = 1;
        argv += 1;
        argc -= 1;
    }
    var retries: c_int = 0;
    var response: *Response = undefined;
    while (true) {
        request[0] = cli_version;
        response = send(intf, 0x19, request[0..9]) orelse {
            log.print(log.Level.err, "Sun OEM cli command failed", .{});
            return -1;
        };
        const raw = bytes(response);
        const message = cliMessage(raw);
        const server_error = if (raw.len > 1) raw[1] else 0;
        if (server_error != 0 or response.ccode != 0) {
            if (eql(&message, "Invalid version") or eql(@ptrCast(&message[1]), "Invalid version")) {
                if (cli_version == 2) {
                    cli_version = 1;
                    continue;
                }
            } else if (eql(&message, "Busy") and retries < 3) {
                retries += 1;
                log.print(log.Level.info, "Failed to connect: %s, retrying", .{@as([*:0]const u8, @ptrCast(&message))});
                _ = c.sleep(2);
                continue;
            }
            log.print(log.Level.err, "Failed to connect: %s", .{@as([*:0]const u8, @ptrCast(&message))});
            return -1;
        }
        if (raw.len < 8) {
            log.print(log.Level.err, "Sun OEM cli command failed", .{});
            return -1;
        }
        break;
    }
    if (cli_version == 2) request[2] ^= 1;
    _ = c.printf("Connected. Use ^D to exit.\n");
    _ = c.fflush(null);
    @memcpy(request[4..8], response.data[4..8]);
    request[1] = 3;
    var original_terminal: c.struct_termios = undefined;
    if (argc == 0) {
        if (c.tcgetattr(c.fileno(c.stdin), &original_terminal) != 0) {
            log.print(log.Level.err, "Failed to set interactive mode: %s", .{c.strerror(c.__errno_location().*)});
            return -1;
        }
        var terminal = original_terminal;
        terminal.c_lflag &= ~@as(@TypeOf(terminal.c_lflag), @intCast(c.ICANON | c.ECHO | c.ISIG));
        terminal.c_cc[c.VMIN] = 1;
        if (c.tcsetattr(c.fileno(c.stdin), c.TCSAFLUSH, &terminal) != 0) {
            log.print(log.Level.err, "Failed to set interactive mode: %s", .{c.strerror(c.__errno_location().*)});
            return -1;
        }
    }
    var arg_num: usize = 0;
    var arg_pos: usize = 0;
    var first_char = false;
    var wait_time: c.time_t = 0;
    var command_response: u8 = 0;
    var error_flag = false;
    while (response.ccode == 0 and command_response == 0) {
        var count: usize = 0;
        request[8] = 0;
        if (argc == 0) {
            var tv = c.struct_timeval{ .tv_sec = 0, .tv_usec = 500000 };
            var rfds: c.fd_set = std.mem.zeroes(c.fd_set);
            std.mem.asBytes(&rfds)[0] = 1;
            const ready = c.select(1, &rfds, null, null, &tv);
            if (ready < 0) {
                _ = c.printf("Broken pipe\n");
                request[1] = 2;
            } else if (ready > 0) {
                const read_count = c.read(0, &request[8], 1);
                if (read_count <= 0 or (first_char and request[8] == 4)) {
                    request[1] = 4;
                } else {
                    count = @intCast(read_count);
                }
                first_char = request[8] == '\n' or request[8] == '\r';
            }
        } else {
            const now = c.time(null);
            if (now < wait_time) {
                // Delayed command: send an empty poll in the meantime.
            } else if (arg_num >= @as(usize, @intCast(argc))) {
                request[1] = 4;
            } else if (eql(arg(argv, arg_num), "@wait=")) {
                var delay: c_int = 0;
                if (text(arg(argv, arg_num)).len > 6 and c.str2int(arg(argv, arg_num) + 6, &delay) != 0) delay = 0;
                wait_time = now + @max(delay, 0);
                arg_num += 1;
            } else {
                const current = text(arg(argv, arg_num));
                while (arg_pos < current.len and count < 70) : ({
                    arg_pos += 1;
                    count += 1;
                }) request[8 + count] = current[arg_pos];
                if (arg_pos == current.len) {
                    request[8 + count] = '\n';
                    count += 1;
                    arg_pos = 0;
                    arg_num += 1;
                }
            }
        }
        while (true) {
            request[8 + count] = 0;
            var attempt: usize = 0;
            while (true) {
                response = send(intf, 0x19, request[0 .. 8 + count + 1]) orelse {
                    log.print(log.Level.err, "Communication error.", .{});
                    error_flag = true;
                    break;
                };
                if (response.ccode != 0xc3) break;
                if (attempt == 3) {
                    log.print(log.Level.err, "Excessive timeout.", .{});
                    error_flag = true;
                    break;
                }
                attempt += 1;
            }
            if (error_flag) break;
            if (cli_version == 2) request[2] ^= 1;
            const raw = bytes(response);
            if (raw.len < 8) {
                log.print(log.Level.err, "Communication error.", .{});
                error_flag = true;
                break;
            }
            const message = cliMessage(raw);
            _ = c.printf("%s", @as([*:0]const u8, @ptrCast(&message)));
            _ = c.fflush(null);
            count = 0;
            command_response = raw[1];
            if (request[1] == 4 and command_response != 0 and response.ccode == 0) command_response = 1;
            if (command_response != 0 or message[0] == 0) break;
        }
        if (error_flag) break;
    }
    if (argc == 0 and c.tcsetattr(c.fileno(c.stdin), c.TCSAFLUSH, &original_terminal) != 0) {
        log.print(log.Level.err, "Failed to restore interactive mode: %s", .{c.strerror(c.__errno_location().*)});
        return -1;
    }
    return if (!error_flag and command_response == 1) 0 else -1;
}

fn sunoemMain(intf: *Intf, argc: c_int, argv: Args) callconv(.c) c_int {
    if (argc <= 0 or eql(arg(argv, 0), "help")) {
        usage();
        return 0;
    }
    const command = arg(argv, 0);
    if (eql(command, "cli")) return cli(intf, argc - 1, argv + 1);
    if (eql(command, "led") or eql(command, "sbled")) {
        if (argc < 2) {
            usage();
            return -1;
        }
        if (eql(arg(argv, 1), "get")) {
            if (argc < 3) {
                const all: [*:0]u8 = @constCast("all");
                const fake = [_][*c]u8{@ptrCast(all)};
                return led(intf, false, 1, @ptrCast(@constCast(&fake)));
            }
            return led(intf, false, argc - 2, argv + 2);
        }
        if (eql(arg(argv, 1), "set")) {
            if (argc < 4) {
                usage();
                return -1;
            }
            return led(intf, true, argc - 2, argv + 2);
        }
        usage();
        return -1;
    }
    if (eql(command, "sshkey")) {
        if (argc < 3) {
            usage();
            return -1;
        }
        var uid: u8 = 0;
        const result = c.str2uchar(arg(argv, 2), &uid);
        if (result != 0) {
            log.print(log.Level.notice, if (result == 2) "Invalid interval given." else "Given interval is too big.", .{});
            return -1;
        }
        if (eql(arg(argv, 1), "del")) return sshDel(intf, uid);
        if (eql(arg(argv, 1), "set")) {
            if (argc < 4) {
                usage();
                return -1;
            }
            return sshSet(intf, uid, arg(argv, 3));
        }
        usage();
        return -1;
    }
    if (eql(command, "ping")) {
        if (argc < 2) {
            usage();
            return -1;
        }
        return echo(intf, argc - 1, argv + 1);
    }
    if (eql(command, "version")) return version(intf);
    if (eql(command, "nacname")) {
        if (argc < 2) {
            usage();
            return -1;
        }
        return nacname(intf, arg(argv, 1));
    }
    if (eql(command, "getval")) {
        if (argc < 2) {
            usage();
            return -1;
        }
        return getval(intf, arg(argv, 1));
    }
    if (eql(command, "setval")) {
        if (argc < 3) {
            usage();
            return -1;
        }
        return setval(intf, arg(argv, 1), arg(argv, 2), if (argc == 4) arg(argv, 3) else null);
    }
    if (eql(command, "getfile")) {
        if (argc < 3) {
            usage();
            return -1;
        }
        return getfile(intf, arg(argv, 1), arg(argv, 2));
    }
    if (eql(command, "getbehavior")) {
        if (argc < 2) {
            usage();
            return -1;
        }
        return getbehavior(intf, arg(argv, 1));
    }
    log.print(log.Level.err, "Invalid sunoem command: %s", .{command});
    return -1;
}

pub fn exportSymbols() void {
    comptime {
        abi.assertCallSignature(@TypeOf(sunoemMain), @TypeOf(c.ipmi_sunoem_main));
        @export(&sunoemMain, .{ .name = "ipmi_sunoem_main", .linkage = .strong });
        @export(&ret_get, .{ .name = "ret_get", .linkage = .strong });
        @export(&ret_set, .{ .name = "ret_set", .linkage = .strong });
    }
}

test "Sun OEM packed SDR list and LED name" {
    try std.testing.expectEqual(@as(usize, c.ABI_SIZEOF_sdr_record_list), @sizeOf(SdrList));
    try std.testing.expectEqual(@as(usize, c.ABI_OFFSETOF_sdr_record_list__record), @offsetOf(SdrList, "record"));
    var dev: [27]u8 = @splat(0);
    @memcpy(dev[11..16], "LED01");
    const name = deviceName(&dev);
    try std.testing.expectEqualStrings("LED01", std.mem.sliceTo(name[0..], 0));
    try std.testing.expect(entityLogical(0x81));
    try std.testing.expectEqual(@as(u8, 1), entityInstance(0x81));
    try std.testing.expectEqual(@as(u8, 1), entityInstance(entityByte(1)));
    try std.testing.expect(associationIsRange(0x80));
}

test "Sun OEM getfile refuses incomplete and inconsistent BMC blocks" {
    const expected = [_]u8{ 0, 0, 0, 1 };
    const good = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 3, 1, 'A', 'B', 'C' };
    try std.testing.expectEqualStrings("ABC", try fileBlock(&good, &expected));
    try std.testing.expectError(error.ShortReply, fileBlock(good[0..8], &expected));
    try std.testing.expectError(error.InvalidSize, fileBlock(good[0..11], &expected));
    try std.testing.expectError(error.IncorrectBlock, fileBlock(&good, &[_]u8{ 0, 0, 0, 2 }));
    var oversize = good;
    oversize[6] = 4;
    oversize[7] = 1;
    try std.testing.expectError(error.InvalidSize, fileBlock(&oversize, &expected));
}

test "Sun OEM CLI clips an unterminated BMC string" {
    var raw: [80]u8 = @splat('X');
    const message = cliMessage(&raw);
    try std.testing.expectEqual(@as(usize, 71), std.mem.len(@as([*:0]const u8, &message)));
    try std.testing.expectEqual(@as(u8, 'X'), message[70]);
    raw[8] = 0;
    const empty = cliMessage(&raw);
    try std.testing.expectEqual(@as(u8, 0), empty[0]);
}
