//! Staged port of `lib/ipmi_fru.c`. File transfer (`fru read` and `fru write`)
//! and its response validation are implemented here. Other commands still
//! execute the original C code through `fru_legacy.c`, not placeholders:
//! do not remove the shim until print, edit, get, upgEkey, internaluse and the
//! remaining public FRU helper functions have all been ported.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");

const Allocator = std.mem.Allocator;
const Request = ipmi.Request;
const Response = ipmi.Response;

const Info = struct {
    size: u16,
    access: bool,
};

const ReadError = error{ OutOfRange, InvalidMaxSize, Failed, ShortResponse };

fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    const send = intf.sendrecv orelse return null;
    return send(intf, req);
}

fn cIntf(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}

fn equals(a: [*c]u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(a))), b);
}

fn validFilename(path: [*c]u8) bool {
    if (path == null) {
        c.lprintf(log.Level.err, "ERROR: NULL pointer passed.");
        return false;
    }
    const length = c.strlen(path);
    if (length < 1) {
        c.lprintf(log.Level.err, "File/path is invalid.");
        return false;
    }
    if (length >= 512) {
        c.lprintf(log.Level.err, "File/path must be shorter than 512 bytes.");
        return false;
    }
    return true;
}

/// Read FRU Inventory Area Info, validating the three bytes before decoding
/// them. A malformed response must never read stale transport-buffer contents.
fn getInfo(intf: *Intf, id: u8) ?Info {
    var data = [1]u8{id};
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.GET_FRU_INFO;
    req.msg.data = &data;
    req.msg.data_len = 1;

    const rsp = sendrecv(intf, &req) orelse return null;
    if (rsp.ccode != 0) {
        if (rsp.ccode == c.IPMI_CC_TIMEOUT)
            _ = c.printf("  Timeout accessing FRU info. (Device not present?)\n");
        return null;
    }
    if (rsp.data_len < 3) {
        c.lprintf(log.Level.err, "FRU info response too short");
        return null;
    }
    return .{
        .size = @as(u16, rsp.data[0]) | (@as(u16, rsp.data[1]) << 8),
        .access = (rsp.data[2] & 1) != 0,
    };
}

fn isTooLarge(code: u8) bool {
    return code == c.IPMI_CC_REQ_DATA_INV_LENGTH or
        code == c.IPMI_CC_REQ_DATA_FIELD_EXCEED or
        code == c.IPMI_CC_CANT_RET_NUM_REQ_BYTES;
}

/// `read_fru_area()`'s request-size, retry and offset rules, using a bounded
/// destination slice. Callers choose whether a failed transfer is fatal.
fn readArea(intf: *Intf, id: u8, info: Info, offset: usize, dest: []u8) ReadError!void {
    if (offset > info.size) {
        c.lprintf(log.Level.err, "Read FRU Area offset incorrect: %d > %d", @as(c_int, @intCast(offset)), @as(c_int, info.size));
        return error.OutOfRange;
    }
    const finish = @min(offset + dest.len, @as(usize, info.size));
    if (offset + dest.len > info.size) {
        c.lprintf(
            log.Level.notice,
            "Read FRU Area length %d too large, Adjusting to %d",
            @as(c_int, @intCast(offset + dest.len)),
            @as(c_int, @intCast(finish - offset)),
        );
    }

    const max_response = c.ipmi_intf_get_max_response_data_size(cIntf(intf));
    if (max_response <= 2) {
        c.lprintf(log.Level.@"error", "Maximum response size is too small to send a read request");
        return error.InvalidMaxSize;
    }
    var max_read: usize = @min(@as(usize, max_response) - 2, 255);
    if (info.access) max_read &= ~@as(usize, 1);
    if (max_read == 0) return error.InvalidMaxSize;

    var request_data: [4]u8 = .{ id, 0, 0, 0 };
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.GET_FRU_DATA;
    req.msg.data = &request_data;
    req.msg.data_len = request_data.len;

    var off = offset;
    while (true) {
        const wire_offset: usize = if (info.access) off >> 1 else off;
        request_data[1] = @truncate(wire_offset);
        request_data[2] = @truncate(wire_offset >> 8);
        request_data[3] = @intCast(@min(finish - off, max_read));

        const rsp = sendrecv(intf, &req) orelse {
            c.lprintf(log.Level.notice, "FRU Read failed");
            return error.Failed;
        };
        if (rsp.ccode != 0) {
            if (isTooLarge(rsp.ccode) and max_read > 8) {
                max_read -= if (max_read > 32) 8 else 1;
                c.lprintf(log.Level.info, "Retrying FRU read with request size %d", @as(c_int, @intCast(max_read)));
                continue;
            }
            c.lprintf(log.Level.notice, "FRU Read failed: %s", c.val2str(rsp.ccode, c.completion_code_vals));
            return error.Failed;
        }

        const data_len: usize = if (rsp.data_len < 0) 0 else @intCast(rsp.data_len);
        if (data_len < 1) {
            _ = c.printf(" Not enough buffer size");
            return error.ShortResponse;
        }
        const count: usize = if (info.access) @as(usize, rsp.data[0]) << 1 else rsp.data[0];
        if (count > data_len - 1 or count > finish - off) {
            _ = c.printf(" Not enough buffer size");
            return error.ShortResponse;
        }
        @memcpy(dest[off - offset ..][0..count], rsp.data[1..][0..count]);
        off += count;
        if (off >= finish or count == 0) return;
    }
}

fn transfer(intf: *Intf, id: u8, path: [*c]u8, allocator: Allocator, write: bool) void {
    const info = getInfo(intf, id) orelse return;
    if (c.verbose != 0) {
        _ = c.printf("Fru Size   = %d bytes\n", @as(c_int, info.size));
        _ = c.printf("Fru Access = %xh\n", @as(c_uint, @intFromBool(info.access)));
    }
    const data = allocator.alloc(u8, info.size) catch {
        c.lprintf(log.Level.err, "Cannot allocate %d bytes\n", @as(c_int, info.size));
        return;
    };
    defer allocator.free(data);
    @memset(data, 0);

    if (write) {
        var length: usize = 0;
        if (c.fopen(path, "rb")) |file| {
            length = c.fread(data.ptr, 1, data.len, file);
            _ = c.printf("Fru Size         : %d bytes\n", @as(c_int, info.size));
            _ = c.printf("Size to Write    : %d bytes\n", @as(c_int, @intCast(length)));
            _ = c.fclose(file);
        } else {
            c.lprintf(log.Level.err, "Error opening file %s\n", path);
        }
        if (length > 0) {
            _ = c.ipmi_fru_zig_write(cIntf(intf), info.size, @intFromBool(info.access), id, @intCast(length), data.ptr);
            c.lprintf(log.Level.info, "Done");
        }
    } else {
        _ = c.printf("Fru Size         : %d bytes\n", @as(c_int, info.size));
        // The C CLI writes a file even if its FRU read failed. Keep that
        // observable CLI behavior, but never write uninitialized bytes.
        readArea(intf, id, info, 0, data) catch {};
        const file = c.fopen(path, "wb") orelse {
            c.lprintf(log.Level.err, "Error opening file %s\n", path);
            return;
        };
        defer _ = c.fclose(file);
        _ = c.fwrite(data.ptr, data.len, 1, file);
        _ = c.printf("Done\n");
    }
}

fn fruMain(intf: ?*Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    const in = intf orelse return -1;
    if (argc < 1 or (!equals(argv[0], "read") and !equals(argv[0], "write")))
        return c.ipmi_fru_main_legacy(cIntf(in), argc, argv);

    const write = equals(argv[0], "write");
    if (argc > 1 and equals(argv[1], "help")) {
        if (write) c.ipmi_fru_write_help() else c.ipmi_fru_read_help();
        return 0;
    }
    if (argc < 3) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        if (write) c.ipmi_fru_write_help() else c.ipmi_fru_read_help();
        return -1;
    }
    var id: u8 = 0;
    if (c.is_fru_id(argv[1], &id) != 0 or !validFilename(argv[2]))
        return -1;
    if (c.verbose != 0) {
        _ = c.printf("FRU ID           : %d\n", @as(c_int, id));
        _ = c.printf("FRU File         : %s\n", argv[2]);
    }
    transfer(in, id, argv[2], std.heap.page_allocator, write);
    return 0;
}

pub fn exportSymbols() void {
    comptime {
        abi.assertCallSignature(@TypeOf(fruMain), @TypeOf(c.ipmi_fru_main));
        @export(&fruMain, .{ .name = "ipmi_fru_main", .linkage = .strong });
    }
}
