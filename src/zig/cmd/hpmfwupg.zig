//! HPM.1 firmware upgrade agent (`lib/ipmi_hpmfwupg.c`).
//! The dummy-interface goldens cover the wire protocol without contacting
//! hardware. Image and response parsing uses checked slices; no packet or
//! image length from the BMC/file is ever trusted as a pointer offset.
//! Diagnostics use typed `log.print()` from the same selected archive as the
//! Zig logger state; without it, `log.print()` calls the original C `lprintf`.
//! Both paths keep libc printf formatting and the original argument widths.
//! The two runtime-chosen headings select only fixed, conversion-free strings.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;
const notice = log.Level.notice;
const err = log.Level.err;

const view_mode: c_int = 1;
const debug_mode: c_int = 2;
const force_mode: c_int = 4;
const compare_mode: c_int = 8;
const target_ver: c_int = 1;
const rollback_ver: c_int = 2;
const image_ver: c_int = 4;

const Version = extern struct {
    componentId: u8 = 0,
    targetMajor: u8 = 0,
    targetMinor: u8 = 0,
    targetAux: [4]u8 = .{0} ** 4,
    rollbackMajor: u8 = 0,
    rollbackMinor: u8 = 0,
    rollbackAux: [4]u8 = .{0} ** 4,
    deferredMajor: u8 = 0,
    deferredMinor: u8 = 0,
    deferredAux: [4]u8 = .{0} ** 4,
    imageMajor: u8 = 0,
    imageMinor: u8 = 0,
    imageAux: [4]u8 = .{0} ** 4,
    coldResetRequired: u8 = 0,
    rollbackSupported: u8 = 0,
    deferredActivationSupported: u8 = 0,
    descString: [13]u8 = .{0} ** 13,
};

pub var gVersionInfo: [8]Version = .{std.mem.zeroes(Version)} ** 8;
var old_percent: c_int = -1;
var error_count: c_int = 0;
var valid_upload_size = false;
var lan_size_errors: c_int = 0;
var fake_rsp: Response = std.mem.zeroes(Response);

comptime {
    abi.assertLayout(Version, c.VERSIONINFO);
}

const Capabilities = struct {
    version: u8 = 0,
    flags: u8 = 0,
    upgrade_timeout: u8 = 0,
    selftest_timeout: u8 = 0,
    rollback_timeout: u8 = 0,
    inaccess_timeout: u8 = 0,
    components: u8 = 0,

    fn contains(self: Capabilities, id: usize) bool {
        return (self.components & (@as(u8, 1) << @intCast(id))) != 0;
    }
};

const Property = struct {
    data: [13]u8 = .{0} ** 13,
    len: u8 = 0,

    fn flags(self: Property) u8 {
        return self.data[1];
    }
};

const Device = struct {
    id: u8,
    revision: u8,
    fw1: u8,
    fw2: u8,
    manufacturer: [3]u8,
    product: [2]u8,
};

const Upgrade = struct {
    image: []const u8,
    header: Header,
    target: Capabilities = .{},
    properties: [8]u8 = .{0} ** 8,
    device: Device = undefined,
    mask: u8 = 0,
    component: u8 = 0,
};

fn bit(value: u8, index: u3) bool {
    return (value & (@as(u8, 1) << index)) != 0;
}

fn yn(value: bool) u8 {
    return if (value) 'y' else 'n';
}

fn le16(data: []const u8) u16 {
    return @as(u16, data[0]) | @as(u16, data[1]) << 8;
}

fn le32(data: []const u8) u32 {
    return @as(u32, data[0]) | @as(u32, data[1]) << 8 |
        @as(u32, data[2]) << 16 | @as(u32, data[3]) << 24;
}

fn put32(data: []u8, value: u32) void {
    data[0] = @truncate(value);
    data[1] = @truncate(value >> 8);
    data[2] = @truncate(value >> 16);
    data[3] = @truncate(value >> 24);
}

fn responseData(rsp: *const Response) ?[]const u8 {
    if (rsp.data_len < 0 or rsp.data_len > rsp.data.len) return null;
    return rsp.data[0..@intCast(rsp.data_len)];
}

fn isLan(intf: *const Intf) bool {
    return std.mem.indexOf(u8, std.mem.sliceTo(&intf.name, 0), "lan") != null;
}

fn retryable(code: u8) bool {
    if (code != 0x83 and code != 0x82 and code != 0x80) return false;
    const previous = error_count;
    error_count += 1;
    return previous < 3;
}

fn sendCmd(intf: *Intf, req: Request, ctx: ?*const Upgrade) ?*Response {
    const inaccess_timeout: i64 = if (ctx) |x| @as(i64, x.target.inaccess_timeout) * 5 else 60;
    const upgrade_timeout: i64 = if (ctx) |x| @as(i64, x.target.upgrade_timeout) * 5 else 60;
    var last = c.time(null);
    var inaccess_elapsed: i64 = 0;
    var upgrade_elapsed: i64 = 0;
    while (true) {
        var copy = req;
        var rsp = intf.sendrecv.?(intf, &copy);
        if (rsp == null and isLan(intf)) {
            log.print(log.Level.debug, "HPM: no response available", .{});
            log.print(log.Level.debug, "HPM: the command may be rejected for security reasons", .{});
            if (req.msg.cmd == 0x32 and lan_size_errors < 6 and !valid_upload_size) {
                log.print(log.Level.debug, "HPM: upload firmware block API called", .{});
                log.print(log.Level.debug, "HPM: returning length error to force resize", .{});
                fake_rsp.ccode = 0xc7;
                fake_rsp.data_len = 0;
                rsp = &fake_rsp;
                lan_size_errors += 1;
            } else if (req.msg.cmd == 0x35 or req.msg.cmd == 0x38) {
                log.print(log.Level.debug, "HPM: activate/rollback firmware API called", .{});
                log.print(log.Level.debug, "HPM: returning in progress to handle IOL session lost", .{});
                fake_rsp.ccode = 0x80;
                fake_rsp.data_len = 0;
                rsp = &fake_rsp;
            } else if ((req.msg.cmd == 0x37 or req.msg.cmd == 0x34 or req.msg.cmd == 0x36) and
                (intf.target_addr == 0 or intf.target_addr == intf.my_addr))
            {
                log.print(log.Level.debug, "HPM: upg/rollback status firmware API called", .{});
                log.print(log.Level.debug, "HPM: try to re-open IOL session", .{});
                intf.abort = 1;
                if (intf.close) |close| close(intf);
                while (inaccess_elapsed < inaccess_timeout) {
                    if (intf.open == null or intf.open.?(intf) != -1) break;
                    const now = c.time(null);
                    inaccess_elapsed += @max(0, now - last);
                    last = now;
                }
                fake_rsp.ccode = 0xc3;
                fake_rsp.data_len = 0;
                rsp = &fake_rsp;
            }
        }
        const code: u8 = if (rsp) |r| r.ccode else 0xff;
        if (rsp == null or code == 0xff or code == 0xc3 or code == 0xd3) {
            if (inaccess_elapsed >= inaccess_timeout) return rsp;
            const now = c.time(null);
            inaccess_elapsed += @max(0, now - last);
            last = now;
            _ = c.usleep(100_000);
            continue;
        }
        if (code == 0xc0) {
            if (upgrade_elapsed >= upgrade_timeout) return rsp;
            const now = c.time(null);
            upgrade_elapsed += @max(0, now - last);
            last = now;
            _ = c.usleep(100_000);
            continue;
        }
        if (code == 0) error_count = 0;
        if (req.msg.cmd == 0x32 and !valid_upload_size) {
            log.print(log.Level.info, "Buffer length is now considered valid", .{});
            valid_upload_size = true;
        }
        return rsp;
    }
}

fn send(intf: *Intf, cmd: u8, bytes: []const u8, ctx: ?*const Upgrade) ?*Response {
    if (bytes.len > std.math.maxInt(u16)) return null;
    var small: [256]u8 = undefined;
    const owned = if (bytes.len > small.len)
        std.heap.c_allocator.alloc(u8, bytes.len) catch {
            log.print(err, "ipmitool: malloc failure", .{});
            return null;
        }
    else
        null;
    defer if (owned) |buffer| std.heap.c_allocator.free(buffer);
    const data = if (owned) |buffer| buffer else small[0..bytes.len];
    @memcpy(data, bytes);
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun = .{ .netfn = 0x2c, .lun = 0 };
    req.msg.cmd = cmd;
    req.msg.data_len = @intCast(bytes.len);
    req.msg.data = if (data.len == 0) null else data.ptr;
    return sendCmd(intf, req, ctx);
}

fn ccText(code: u8) [*c]const u8 {
    return c.val2str(code, c.completion_code_vals);
}

fn getDevice(intf: *Intf) ?Device {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun = .{ .netfn = 0x06, .lun = 0 };
    req.msg.cmd = 1;
    const rsp = sendCmd(intf, req, null) orelse {
        log.print(err, "Error getting device ID.", .{});
        return null;
    };
    if (rsp.ccode != 0) {
        log.print(err, "Error getting device ID.", .{});
        log.print(err, "compcode=0x%x: %s", .{ @as(c_uint, rsp.ccode), ccText(rsp.ccode) });
        return null;
    }
    const data = responseData(rsp) orelse return null;
    if (data.len < 11) {
        log.print(err, "Error getting device ID.", .{});
        return null;
    }
    return .{
        .id = data[0],
        .revision = data[1],
        .fw1 = data[2],
        .fw2 = data[3],
        .manufacturer = data[6..9].*,
        .product = data[9..11].*,
    };
}

fn getCapabilities(intf: *Intf) ?Capabilities {
    const rsp = send(intf, 0x2e, &.{0}, null) orelse {
        log.print(err, "Error getting target upgrade capabilities.", .{});
        return null;
    };
    if (rsp.ccode != 0) {
        log.print(err, "Error getting target upgrade capabilities, ccode: 0x%x: %s", .{ @as(c_uint, rsp.ccode), ccText(rsp.ccode) });
        return null;
    }
    const data = responseData(rsp) orelse return null;
    if (data.len < 8) {
        log.print(err, "Error getting target upgrade capabilities.", .{});
        return null;
    }
    const caps: Capabilities = .{
        .version = data[1],
        .flags = data[2],
        .upgrade_timeout = data[3],
        .selftest_timeout = data[4],
        .rollback_timeout = data[5],
        .inaccess_timeout = data[6],
        .components = data[7],
    };
    if (c.verbose != 0) {
        log.print(notice, "TARGET UPGRADE CAPABILITIES", .{});
        log.print(notice, "-------------------------------", .{});
        log.print(notice, "HPM.1 version............%d    ", .{@as(c_int, caps.version)});
        inline for (0..8) |i| {
            log.print(notice, "Component %d presence....[%c]   ", .{ @as(c_int, i), @as(c_int, yn(caps.contains(i))) });
        }
        log.print(notice, "Upgrade undesirable.....[%c]   ", .{@as(c_int, yn(bit(caps.flags, 7)))});
        log.print(notice, "Aut rollback override...[%c]   ", .{@as(c_int, yn(bit(caps.flags, 6)))});
        log.print(notice, "IPMC degraded...........[%c]   ", .{@as(c_int, yn(bit(caps.flags, 5)))});
        log.print(notice, "Deferred activation.....[%c]   ", .{@as(c_int, yn(bit(caps.flags, 4)))});
        log.print(notice, "Service affected........[%c]   ", .{@as(c_int, yn(bit(caps.flags, 3)))});
        log.print(notice, "Manual rollback.........[%c]   ", .{@as(c_int, yn(bit(caps.flags, 2)))});
        log.print(notice, "Automatic rollback......[%c]   ", .{@as(c_int, yn(bit(caps.flags, 1)))});
        log.print(notice, "Self test...............[%c]   ", .{@as(c_int, yn(bit(caps.flags, 0)))});
        log.print(notice, "Upgrade timeout.........[%d sec] ", .{@as(c_int, caps.upgrade_timeout) * 5});
        log.print(notice, "Self test timeout.......[%d sec] ", .{@as(c_int, caps.selftest_timeout) * 5});
        log.print(notice, "Rollback timeout........[%d sec] ", .{@as(c_int, caps.rollback_timeout) * 5});
        log.print(notice, "Inaccessibility timeout.[%d sec] \n", .{@as(c_int, caps.inaccess_timeout) * 5});
    }
    return caps;
}

fn getProperty(intf: *Intf, id: u8, selector: u8) ?Property {
    const rsp = send(intf, 0x2f, &.{ 0, id, selector }, null) orelse {
        log.print(notice, "Error getting component properties\n", .{});
        return null;
    };
    if (rsp.ccode != 0) {
        log.print(notice, "Error getting component properties", .{});
        log.print(notice, "compcode=0x%x: %s", .{ @as(c_uint, rsp.ccode), ccText(rsp.ccode) });
        return null;
    }
    const need: usize = switch (selector) {
        0 => 2,
        1, 3, 4 => 7,
        2 => 13,
        192 => 5,
        else => {
            log.print(notice, "Unsupported component selector", .{});
            return null;
        },
    };
    const data = responseData(rsp) orelse return null;
    if (data.len < need) {
        log.print(notice, "Error getting component properties\n", .{});
        return null;
    }
    var p: Property = .{ .len = @intCast(need) };
    @memcpy(p.data[0..need], data[0..need]);
    if (c.verbose != 0) printProperty(p, selector);
    return p;
}

fn printProperty(p: Property, selector: u8) void {
    const d = p.data;
    switch (selector) {
        0 => {
            log.print(notice, "GENERAL PROPERTIES", .{});
            log.print(notice, "-------------------------------", .{});
            log.print(notice, "Payload cold reset req....[%c]   ", .{@as(c_int, yn(bit(d[1], 5)))});
            log.print(notice, "Def. activation supported.[%c]   ", .{@as(c_int, yn(bit(d[1], 4)))});
            log.print(notice, "Comparison supported......[%c]   ", .{@as(c_int, yn(bit(d[1], 3)))});
            log.print(notice, "Preparation supported.....[%c]   ", .{@as(c_int, yn(bit(d[1], 2)))});
            log.print(notice, "Rollback supported........[%c]   \n", .{@as(c_int, yn((d[1] & 3) != 0))});
        },
        2 => {
            var text: [13]u8 = .{0} ** 13;
            @memcpy(text[0..12], d[1..13]);
            log.print(notice, "Description string: %s\n", .{&text});
        },
        1, 3, 4 => {
            log.print(notice, switch (selector) {
                1 => "Current Version: ",
                3 => "Rollback FW Version: ",
                else => "Deferred FW Version: ",
            }, .{});
            log.print(notice, " Major: %d", .{@as(c_int, d[1])});
            log.print(notice, " Minor: %x", .{@as(c_uint, d[2])});
            log.print(notice, " Aux  : %03d %03d %03d %03d\n", .{ @as(c_int, d[3]), @as(c_int, d[4]), @as(c_int, d[5]), @as(c_int, d[6]) });
        },
        192 => {
            log.print(notice, "OEM Properties: ", .{});
            for (d[1..5]) |b| log.print(notice, " 0x%x ", .{@as(c_uint, b)});
        },
        else => {},
    }
}

fn getStatus(intf: *Intf, ctx: ?*const Upgrade, silent: bool) ?u8 {
    const rsp = send(intf, 0x34, &.{0}, ctx) orelse {
        log.print(notice, "Error getting upgrade status. Failed to get response.", .{});
        return null;
    };
    if (rsp.ccode == 0) {
        const d = responseData(rsp) orelse return null;
        if (d.len < 3) {
            log.print(notice, "Error getting upgrade status", .{});
            return null;
        }
        if (!silent) {
            log.print(notice, "Upgrade status:", .{});
            log.print(notice, " Command in progress:          %x", .{@as(c_uint, d[1])});
            log.print(notice, " Last command completion code: %x", .{@as(c_uint, d[2])});
        }
        return d[2];
    }
    if (retryable(rsp.ccode)) {
        if (!silent) log.print(log.Level.debug, "HPM: Retryable error detected", .{});
        return 0x80;
    }
    log.print(notice, "Error getting upgrade status", .{});
    log.print(notice, "compcode=0x%x: %s", .{ @as(c_uint, rsp.ccode), ccText(rsp.ccode) });
    return null;
}

fn waitLong(intf: *Intf, ctx: ?*const Upgrade) bool {
    const limit: i64 = if (ctx) |x| @as(i64, x.target.upgrade_timeout) * 5 else blk: {
        const caps = getCapabilities(intf) orelse {
            if (c.verbose != 0) _ = c.printf("Use default timeout: %i seconds\n", @as(c_int, 60));
            break :blk 60;
        };
        if (c.verbose != 0) _ = c.printf("Use Command Upgrade Capabilities Timeout: %i seconds\n", @as(c_int, caps.upgrade_timeout) * 5);
        break :blk @as(i64, caps.upgrade_timeout) * 5;
    };
    if (ctx != null and c.verbose != 0) _ = c.printf("Use File Upgrade Capabilities: %i seconds\n", @as(c_int, @intCast(limit)));
    const started = c.time(null);
    var code = getStatus(intf, ctx, true) orelse return false;
    while ((code == 0x80 or code == 0xd5) and c.time(null) - started < limit) {
        _ = c.usleep(1_000_000);
        code = getStatus(intf, ctx, true) orelse return false;
    }
    return code == 0;
}

fn action(intf: *Intf, mask: u8, kind: u8, ctx: *const Upgrade) bool {
    const rsp = send(intf, 0x31, &.{ 0, mask, kind }, ctx) orelse {
        log.print(err, "Error initiating upgrade action.", .{});
        return false;
    };
    if (rsp.ccode == 0x80) return waitLong(intf, ctx);
    if (rsp.ccode == 0) return true;
    log.print(notice, "Error initiating upgrade action", .{});
    log.print(notice, "compcode=0x%x: %s", .{ @as(c_uint, rsp.ccode), ccText(rsp.ccode) });
    return false;
}

fn abortUpgrade(intf: *Intf) bool {
    const rsp = send(intf, 0x30, &.{0}, null) orelse {
        log.print(err, "Error - aborting upgrade.", .{});
        return false;
    };
    if (rsp.ccode == 0) return true;
    log.print(err, "Error aborting upgrade", .{});
    log.print(err, "compcode=0x%x: %s", .{ @as(c_uint, rsp.ccode), ccText(rsp.ccode) });
    return false;
}

fn activate(intf: *Intf, override: bool, ctx: ?*const Upgrade) bool {
    const data: []const u8 = if (override) &.{ 0, 1 } else &.{0};
    const rsp = send(intf, 0x35, data, ctx) orelse {
        log.print(err, "Error activating firmware.", .{});
        return false;
    };
    if (rsp.ccode == 0x80) {
        _ = c.printf("Waiting firmware activation...");
        _ = c.fflush(c.stdout);
        const ok = waitLong(intf, ctx);
        log.print(notice, if (ok) "OK" else "Failed", .{});
        return ok;
    }
    if (rsp.ccode == 0) return true;
    log.print(err, "Error activating firmware", .{});
    log.print(err, "compcode=0x%x: %s", .{ @as(c_uint, rsp.ccode), ccText(rsp.ccode) });
    return false;
}

fn querySelftest(intf: *Intf, ctx: ?*const Upgrade) ?[2]u8 {
    const limit: i64 = if (ctx) |x| @as(i64, @max(x.header.selftest_timeout, x.target.selftest_timeout)) * 5 else 60;
    const started = c.time(null);
    while (true) {
        _ = c.usleep(100_000);
        const rsp = send(intf, 0x36, &.{0}, ctx) orelse {
            log.print(notice, "Error getting upgrade status\n", .{});
            return null;
        };
        if (retryable(rsp.ccode) and c.time(null) - started < limit) continue;
        if (rsp.ccode == 0x80 and c.time(null) - started < limit) continue;
        if (rsp.ccode != 0) {
            log.print(notice, "Error getting self test results", .{});
            log.print(notice, "compcode=0x%x: %s", .{ @as(c_uint, rsp.ccode), ccText(rsp.ccode) });
            return null;
        }
        const d = responseData(rsp) orelse return null;
        if (d.len < 3) {
            log.print(notice, "Error getting self test results", .{});
            return null;
        }
        if (c.verbose != 0) {
            log.print(notice, "Self test results:", .{});
            log.print(notice, "Result1 = %x", .{@as(c_uint, d[1])});
            log.print(notice, "Result2 = %x", .{@as(c_uint, d[2])});
        }
        return .{ d[1], d[2] };
    }
}

fn rollbackStatus(intf: *Intf, ctx: ?*const Upgrade) bool {
    const limit: i64 = if (ctx) |x| @as(i64, @max(x.header.rollback_timeout, x.target.rollback_timeout)) * 5 else 60;
    const started = c.time(null);
    while (true) {
        _ = c.usleep(100_000);
        const rsp = send(intf, 0x37, &.{0}, ctx) orelse {
            log.print(err, "Error getting upgrade status.", .{});
            return false;
        };
        const code: u8 = if (retryable(rsp.ccode)) 0x80 else rsp.ccode;
        if ((code == 0x80 or code == 0xc3) and c.time(null) - started < limit) continue;
        if (code == 0) {
            const d = responseData(rsp) orelse return false;
            if (d.len < 2) {
                log.print(err, "Error getting rollback status", .{});
                return false;
            }
            if (d[1] != 0) {
                log.print(notice, "Rollback occurred on component mask: 0x%02x", .{@as(c_uint, d[1])});
            } else {
                log.print(notice, "No Firmware rollback occurred", .{});
            }
            return true;
        }
        if (code == 0x81) {
            log.print(err, "Rollback failed on component mask: 0x%02x", .{@as(c_uint, 0)});
        } else {
            log.print(err, "Error getting rollback status", .{});
            log.print(err, "compcode=0x%x: %s", .{ @as(c_uint, code), ccText(code) });
        }
        return false;
    }
}

fn manualRollback(intf: *Intf) bool {
    const previous = c.verbose;
    c.verbose -= 1;
    const caps = getCapabilities(intf);
    c.verbose = previous;
    if (caps == null) return false;
    const ctx: Upgrade = .{ .image = &.{}, .header = .{}, .target = caps.? };
    const rsp = send(intf, 0x38, &.{0}, &ctx) orelse {
        log.print(err, "Error sending manual rollback.", .{});
        return false;
    };
    if (rsp.ccode == 0 or rsp.ccode == 0x80) {
        _ = c.printf("Waiting firmware rollback...");
        _ = c.fflush(c.stdout);
        return rollbackStatus(intf, &ctx);
    }
    log.print(err, "Error sending manual rollback", .{});
    log.print(err, "compcode=0x%x: %s", .{ @as(c_uint, rsp.ccode), ccText(rsp.ccode) });
    return false;
}

const Header = struct {
    device: u8 = 0,
    manufacturer: [3]u8 = .{0} ** 3,
    product: [2]u8 = .{0} ** 2,
    flags: u8 = 0,
    components: u8 = 0,
    selftest_timeout: u8 = 0,
    rollback_timeout: u8 = 0,
    comp_revision: [2]u8 = .{0} ** 2,
    first_record: usize = 0,
};

const Record = struct {
    kind: u8,
    components: u8,
    component: u8 = 0,
    version: [6]u8 = .{0} ** 6,
    description: [21]u8 = .{0} ** 21,
    payload: []const u8 = &.{},
};

const Records = struct {
    image: []const u8,
    pos: usize,
    end: usize,

    fn next(self: *Records) error{Invalid}!?Record {
        if (self.pos == self.end) return null;
        if (self.end - self.pos < 3) {
            log.print(notice, "    Invalid Action record.", .{});
            return error.Invalid;
        }
        const action_header = self.image[self.pos..][0..3];
        const kind = action_header[0];
        const mask = action_header[1];
        const first_ok = checksum(action_header) == 0;
        if (kind == 2 and !first_ok and self.end - self.pos >= 34 and
            checksum(self.image[self.pos..][0..34]) == 0)
        {
            // HPM.1 permits both 3-byte and 34-byte upload-record checksums.
        } else if (!first_ok) {
            log.print(notice, "    Invalid Action record.", .{});
            return error.Invalid;
        }
        self.pos += 3;
        if (kind == 0 or kind == 1) return .{ .kind = kind, .components = mask };
        if (kind != 2) {
            log.print(notice, "    Invalid Action type. Cannot continue", .{});
            return error.Invalid;
        }
        if (mask == 0 or self.end - self.pos < 31) {
            log.print(notice, "    Invalid Action record.", .{});
            return error.Invalid;
        }
        const details = self.image[self.pos..][0..31];
        const size: usize = le32(details[27..31]);
        self.pos += 31;
        if (size > self.end - self.pos) {
            log.print(notice, "    Invalid firmware image length.", .{});
            return error.Invalid;
        }
        const payload = self.image[self.pos..][0..size];
        self.pos += size;
        return .{
            .kind = 2,
            .components = mask,
            .component = @intCast(7 - @clz(mask)),
            .version = details[0..6].*,
            .description = details[6..27].*,
            .payload = payload,
        };
    }
};

fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum;
}

fn validateImage(image: []const u8) ?Header {
    if (image.len < 16) {
        log.print(notice, "\n    Invalid MD5 signature", .{});
        return null;
    }
    const body = image[0 .. image.len - 16];
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(body, &md5, .{});
    if (!std.mem.eql(u8, &md5, image[image.len - 16 ..])) {
        log.print(notice, "\n    Invalid MD5 signature", .{});
        return null;
    }
    if (body.len < 35) {
        log.print(notice, "\n    Invalid header checksum", .{});
        return null;
    }
    if (!std.mem.eql(u8, body[0..8], "PICMGFWU")) {
        log.print(notice, "\n    Invalid image signature", .{});
        return null;
    }
    if (body[8] != 0) {
        log.print(notice, "\n    Unrecognized image version", .{});
        return null;
    }
    const oem_len: usize = le16(body[32..34]);
    if (oem_len > body.len - 35 or checksum(body[0 .. 35 + oem_len]) != 0) {
        log.print(notice, "\n    Invalid header checksum", .{});
        return null;
    }
    return .{
        .device = body[9],
        .manufacturer = body[10..13].*,
        .product = body[13..15].*,
        .flags = body[19],
        .components = body[20],
        .selftest_timeout = body[21],
        .rollback_timeout = body[22],
        .comp_revision = body[24..26].*,
        .first_record = 35 + oem_len,
    };
}

fn readImage(filename: [*:0]u8) ?[]u8 {
    const file = c.fopen(filename, "rb") orelse {
        log.print(err, "Cannot open image file '%s'", .{filename});
        return null;
    };
    defer _ = c.fclose(file);
    if (c.fseek(file, 0, c.SEEK_END) != 0) {
        log.print(err, "Failed to seek in the image file '%s'", .{filename});
        return null;
    }
    const end = c.ftell(file);
    if (end < 0 or end > std.math.maxInt(u32)) {
        log.print(err, "Failed to seek in the image file '%s'", .{filename});
        return null;
    }
    const buffer = std.heap.c_allocator.alloc(u8, @intCast(end)) catch {
        log.print(err, "ipmitool: malloc failure", .{});
        return null;
    };
    if (c.fseek(file, 0, c.SEEK_SET) != 0 or c.fread(buffer.ptr, 1, buffer.len, file) != buffer.len) {
        log.print(err, "Failed to read file %s size %d", .{ filename, @as(c_int, @truncate(end)) });
        std.heap.c_allocator.free(buffer);
        return null;
    }
    return buffer;
}

fn displayLine(ch: u8, count: usize) void {
    for (0..count) |_| _ = c.printf("%c", @as(c_int, ch));
    _ = c.printf("\n");
}

fn displayVersionHeader(mode: c_int) void {
    displayLine('-', 74);
    _ = c.printf("|ID  | Name        |                     Versions                        |\n");
    _ = c.printf("|    |             |     Active      |     Backup      |      %s   |\n", if (mode & image_ver != 0) @as([*:0]const u8, "File    ") else "Deferred");
    displayLine('-', 74);
}

fn displayUpgradeHeader() void {
    _ = c.printf("\n");
    displayLine('-', 79);
    _ = c.printf("|ID  | Name        |                     Versions                        | %%  |\n");
    _ = c.printf("|    |             |      Active     |      Backup     |      File       |    |\n");
    _ = c.printf("|----|-------------|-----------------|-----------------|-----------------|----|\n");
}

fn printRevision(major: u8, minor: u8, aux: [4]u8) void {
    if ((major == 0xff or major == 0x7f) and minor == 0xff) {
        _ = c.printf(" ---.-- -------- |");
    } else {
        _ = c.printf(" %3d.%02x %02X%02X%02X%02X |", @as(c_int, major), @as(c_uint, minor), @as(c_uint, aux[0]), @as(c_uint, aux[1]), @as(c_uint, aux[2]), @as(c_uint, aux[3]));
    }
}

fn displayVersion(mode: c_int, ver: *const Version, would_upgrade: bool) void {
    _ = c.printf("|%c%c%2d|%-13s|", @as(c_int, if (ver.coldResetRequired != 0) '*' else ' '), @as(c_int, if (would_upgrade) '^' else ' '), @as(c_int, ver.componentId), &ver.descString);
    if (mode & target_ver != 0) {
        printRevision(ver.targetMajor, ver.targetMinor, ver.targetAux);
        if (mode & rollback_ver != 0) {
            printRevision(ver.rollbackMajor, ver.rollbackMinor, ver.rollbackAux);
        } else {
            _ = c.printf(" ---.-- -------- |");
        }
    }
    if (mode & image_ver != 0) {
        if ((ver.imageMajor == 0xff or ver.imageMajor == 0x7f) and ver.imageMinor == 0xff) {
            _ = c.printf(" ---.-- |");
        } else {
            printRevision(ver.imageMajor, ver.imageMinor, ver.imageAux);
        }
    } else {
        printRevision(ver.deferredMajor, ver.deferredMinor, ver.deferredAux);
    }
}

fn displayUpgrade(skip: bool, sent: usize, size: usize, elapsed: i64) void {
    if (skip) {
        _ = c.printf("Skip|\n");
        return;
    }
    _ = c.fflush(c.stdout);
    const percent: c_int = @intFromFloat(@as(f32, @floatFromInt(sent)) / @as(f32, @floatFromInt(size)) * 100);
    if (percent != old_percent) {
        if (old_percent != -1) _ = c.printf("\x08\x08\x08\x08\x08");
        _ = c.printf("%3d%%|", percent);
        old_percent = percent;
    }
    if (sent == size) {
        _ = c.printf("\n|    |Upload Time: %02ld:%02ld             | Image Size: %7d bytes              |\n", @as(c_long, @intCast(@divTrunc(elapsed, 60))), @as(c_long, @intCast(@mod(elapsed, 60))), @as(c_int, @intCast(sent)));
        old_percent = -1;
    }
}

fn targetCheck(intf: *Intf, option: c_int) bool {
    const dev = getDevice(intf) orelse {
        log.print(notice, "Verify whether the Target board is present \n", .{});
        return false;
    };
    const caps = getCapabilities(intf) orelse {
        log.print(notice, "Board might not be supporting the HPM.1 Standards\n", .{});
        return false;
    };
    if (option & view_mode != 0) {
        log.print(notice, "-------Target Information-------", .{});
        log.print(notice, "Device Id          : 0x%x", .{@as(c_uint, dev.id)});
        log.print(notice, "Device Revision    : 0x%x", .{@as(c_uint, dev.revision)});
        log.print(notice, "Product Id         : 0x%04x", .{@as(c_uint, le16(&dev.product))});
        const man = le16(dev.manufacturer[0..2]);
        log.print(notice, "Manufacturer Id    : 0x%04x (%s)\n\n", .{ @as(c_uint, man), c.val2str(man, c.ipmi_oem_info) });
        displayVersionHeader(target_ver | rollback_ver);
    }
    for (0..8) |id| {
        if (!caps.contains(id)) continue;
        const v = &gVersionInfo[id];
        v.* = std.mem.zeroes(Version);
        const general = getProperty(intf, @intCast(id), 0) orelse {
            log.print(notice, "Get CompGenProp Failed for component Id %d\n", .{@as(c_int, @intCast(id))});
            return false;
        };
        v.rollbackSupported = general.flags() & 3;
        v.coldResetRequired = @intFromBool(bit(general.flags(), 5));
        v.deferredActivationSupported = @intFromBool(bit(general.flags(), 4));
        const desc = getProperty(intf, @intCast(id), 2) orelse {
            log.print(notice, "Get CompDescString Failed for component Id %d\n", .{@as(c_int, @intCast(id))});
            return false;
        };
        @memcpy(v.descString[0..12], desc.data[1..13]);
        v.descString[12] = 0;
        const current = getProperty(intf, @intCast(id), 1) orelse {
            log.print(notice, "Get CompCurrentVersion Failed for component Id %d\n", .{@as(c_int, @intCast(id))});
            return false;
        };
        v.componentId = @intCast(id);
        v.targetMajor = current.data[1];
        v.targetMinor = current.data[2];
        @memcpy(&v.targetAux, current.data[3..7]);
        var mode: c_int = target_ver;
        if (v.rollbackSupported != 0) {
            if (getProperty(intf, @intCast(id), 3)) |rolled| {
                v.rollbackMajor = rolled.data[1];
                v.rollbackMinor = rolled.data[2];
                @memcpy(&v.rollbackAux, rolled.data[3..7]);
            } else {
                log.print(notice, "Get CompRollbackVersion Failed for component Id %d\n", .{@as(c_int, @intCast(id))});
            }
            mode |= rollback_ver;
        } else {
            v.rollbackMajor = 0xff;
            v.rollbackMinor = 0xff;
            @memset(&v.rollbackAux, 0xff);
        }
        if (v.deferredActivationSupported != 0) {
            if (getProperty(intf, @intCast(id), 4)) |deferred| {
                v.deferredMajor = deferred.data[1];
                v.deferredMinor = deferred.data[2];
                @memcpy(&v.deferredAux, deferred.data[3..7]);
            } else {
                log.print(notice, "Get CompRollbackVersion Failed for component Id %d\n", .{@as(c_int, @intCast(id))});
            }
        } else {
            v.deferredMajor = 0xff;
            v.deferredMinor = 0xff;
            @memset(&v.deferredAux, 0xff);
        }
        if (option & view_mode != 0) {
            displayVersion(mode, v, false);
            _ = c.printf("\n");
        }
    }
    if (option & view_mode != 0) {
        displayLine('-', 74);
        _ = c.fflush(c.stdout);
        log.print(notice, "(*) Component requires Payload Cold Reset", .{});
        _ = c.printf("\n\n");
    }
    return true;
}

fn ask(prompt: [*:0]const u8) bool {
    var answer: [2]u8 = .{0} ** 2;
    _ = c.printf("%s", prompt);
    const result = c.scanf("%1s", &answer);
    if (result != 1) return false;
    return c.toupper(answer[0]) == 'Y';
}

fn preparation(intf: *Intf, ctx: *Upgrade, option: c_int) bool {
    const dev = getDevice(intf) orelse return false;
    ctx.device = dev;
    const header = ctx.header;
    const ids_match = header.device == dev.id and std.mem.eql(u8, &header.product, &dev.product) and
        std.mem.eql(u8, &header.manufacturer, &dev.manufacturer);
    if (!ids_match) {
        if (header.device != dev.id) {
            log.print(notice, "\n    Invalid device ID %x", .{@as(c_uint, dev.id)});
        } else if (!std.mem.eql(u8, &header.product, &dev.product)) {
            log.print(notice, "\n    Invalid image file for product %u", .{@as(c_uint, le16(&dev.product))});
        } else {
            log.print(notice, "\n    Invalid image file for manufacturer %u", .{@as(c_uint, le16(dev.manufacturer[0..2]))});
        }
        if (option & (force_mode | view_mode) == 0) {
            _ = c.printf("\n\n Use \"force\" option for copying all the components\n");
            return false;
        }
        _ = c.printf("\n    Image Information\n        Device Id : 0x%x\n        Prod   Id : 0x%02x%02x\n        Manuf  Id : 0x%02x%02x%02x", @as(c_uint, header.device), @as(c_uint, header.product[1]), @as(c_uint, header.product[0]), @as(c_uint, header.manufacturer[2]), @as(c_uint, header.manufacturer[1]), @as(c_uint, header.manufacturer[0]));
        _ = c.printf("\n    Board Information\n        Device Id : 0x%x\n        Prod   Id : 0x%02x%02x\n        Manuf  Id : 0x%02x%02x%02x", @as(c_uint, dev.id), @as(c_uint, dev.product[1]), @as(c_uint, dev.product[0]), @as(c_uint, dev.manufacturer[2]), @as(c_uint, dev.manufacturer[1]), @as(c_uint, dev.manufacturer[0]));
        if (!ask("\n Continue ignoring DeviceID/ProductID/ManufacturingID (Y/N): ")) return false;
    }
    if (header.comp_revision[0] > dev.fw1 or
        (header.comp_revision[0] == dev.fw1 and header.comp_revision[1] > dev.fw2))
    {
        log.print(notice, "\n    Version: Major: %d", .{@as(c_int, header.comp_revision[0])});
        log.print(notice, "             Minor: %x", .{@as(c_uint, header.comp_revision[1])});
        log.print(notice, "    Not compatible with ", .{});
        log.print(notice, "    Version: Major: %d", .{@as(c_int, dev.fw1)});
        log.print(notice, "             Minor: %x", .{@as(c_uint, dev.fw2)});
        if (option & (force_mode | view_mode) == 0 or !ask("\n Continue IGNORING Earliest compatibility (Y/N): ")) return false;
    }
    ctx.target = getCapabilities(intf) orelse return false;
    if (option & view_mode == 0) {
        if (header.components & ctx.target.components != header.components) {
            log.print(notice, "\n    Some components present in the image file are not supported by the IPMC", .{});
            return false;
        }
        if (bit(ctx.target.flags, 7)) {
            log.print(notice, "\n    Upgrade undesirable at this moment", .{});
            return false;
        }
        if (option & compare_mode == 0 and (bit(ctx.target.flags, 3) or bit(header.flags, 4)) and
            !ask("\nServices may be affected during upgrade. Do you wish to continue? (y/n): "))
        {
            return false;
        }
    }
    for (0..8) |id| {
        ctx.properties[id] = 0;
        if (bit(header.components, @intCast(id))) {
            const prop = getProperty(intf, @intCast(id), 0) orelse return false;
            ctx.properties[id] = prop.flags();
        }
    }
    return true;
}

fn upgradable(v: *const Version) bool {
    const image = [_]u8{ v.imageMajor, v.imageMinor } ++ v.imageAux;
    const active = [_]u8{ v.targetMajor, v.targetMinor } ++ v.targetAux;
    const rollback = [_]u8{ v.rollbackMajor, v.rollbackMinor } ++ v.rollbackAux;
    if (!std.mem.eql(u8, &image, &active)) return true;
    return v.rollbackSupported != 0 and !std.mem.eql(u8, &image, &rollback);
}

fn records(ctx: *const Upgrade) Records {
    return .{ .image = ctx.image, .pos = ctx.header.first_record, .end = ctx.image.len - 16 };
}

fn precheck(ctx: *Upgrade, selected: c_int, option: c_int) bool {
    var it = records(ctx);
    if (option & view_mode != 0) displayVersionHeader(target_ver | rollback_ver | image_ver);
    while (true) {
        const record = (it.next() catch return false) orelse break;
        if (record.components != 0 and ctx.target.components == 0) {
            log.print(notice, "    Invalid action record. One or more affected components is not supported", .{});
            return false;
        }
        if (record.kind == 0 or record.kind == 1) {
            for (0..8) |id| {
                if (!bit(record.components, @intCast(id))) continue;
                if (record.kind == 0 and ctx.properties[id] & 3 == 0) {
                    log.print(notice, "    Component ID %d does not support backup", .{@as(c_int, @intCast(id))});
                    return false;
                }
                if (record.kind == 1 and !bit(ctx.properties[id], 2)) {
                    log.print(notice, "    Component ID %d does not support preparation", .{@as(c_int, @intCast(id))});
                    return false;
                }
            }
            continue;
        }
        const v = &gVersionInfo[record.component];
        v.imageMajor = record.version[0];
        v.imageMinor = record.version[1];
        @memcpy(&v.imageAux, record.version[2..6]);
        var use = selected == 0 or (selected & record.components) != 0;
        if (use and option & (force_mode | compare_mode) == 0) use = upgradable(v);
        if (c.verbose != 0) {
            log.print(notice, "%s component %d", .{ if (use) @as([*:0]const u8, "Updating") else "Skipping", @as(c_int, record.component) });
        }
        if (use) ctx.mask |= @as(u8, 1) << @intCast(record.component);
        if (option & view_mode != 0) {
            const mode: c_int = target_ver | image_ver | if (v.rollbackSupported != 0) @as(c_int, rollback_ver) else 0;
            displayVersion(mode, v, use);
            _ = c.printf("\n");
        }
    }
    if (option & view_mode != 0) {
        displayLine('-', 74);
        _ = c.fflush(c.stdout);
        log.print(notice, "(*) Component requires Payload Cold Reset", .{});
        log.print(notice, "(^) Indicates component would be upgraded", .{});
    }
    return true;
}

const BlockResult = union(enum) {
    ok: struct { offset: usize = 0, length: usize = 0 },
    resize,
    retry,
    failed,
};

fn uploadBlock(intf: *Intf, data: []const u8, ctx: *const Upgrade) BlockResult {
    const rsp = send(intf, 0x32, data, ctx) orelse {
        log.print(notice, "Error uploading firmware block.", .{});
        return .failed;
    };
    var offset: usize = 0;
    var length: usize = 0;
    var code = rsp.ccode;
    if (code == 0 or code == 0x80) {
        const d = responseData(rsp) orelse return .failed;
        if (d.len > 1) {
            if (d.len == 9) {
                offset = le32(d[1..5]);
                length = le32(d[5..9]);
            } else {
                log.print(notice, "Error wrong rsp->datalen %d for Upload Firmware block command\n", .{@as(c_int, @intCast(d.len))});
                code = 0x82;
            }
        }
    }
    if (code == 0x80) {
        if (waitLong(intf, ctx)) return .{ .ok = .{ .offset = offset, .length = length } };
        return .failed;
    }
    if (code == 0) return .{ .ok = .{ .offset = offset, .length = length } };
    if (retryable(code)) {
        log.print(log.Level.debug, "HPM: [PATCH]Retryable error detected", .{});
        return .retry;
    }
    if (code == 0xc7 or code == 0xc8) return .resize;
    log.print(err, "Error uploading firmware block", .{});
    log.print(err, "compcode=0x%x: %s", .{ @as(c_uint, code), ccText(code) });
    return .failed;
}

fn finishUpload(intf: *Intf, component: u8, sent: usize, ctx: *const Upgrade, option: c_int) bool {
    var req: [6]u8 = .{ 0, component, 0, 0, 0, 0 };
    put32(req[2..6], @intCast(sent));
    const rsp = send(intf, 0x33, &req, ctx) orelse {
        log.print(err, "Error fininshing firmware upload.", .{});
        return false;
    };
    if (rsp.ccode == 0x80) return waitLong(intf, ctx);
    if (option & compare_mode != 0 and rsp.ccode == 0x83) {
        _ = c.printf("|    |Component's active copy doesn't match the upgrade image                 |\n");
        return true;
    }
    if (option & compare_mode != 0 and rsp.ccode == 0) {
        _ = c.printf("|    |Comparison passed                                                       |\n");
        return true;
    }
    if (rsp.ccode == 0) return true;
    log.print(err, "Error finishing firmware upload", .{});
    log.print(err, "compcode=0x%x: %s", .{ @as(c_uint, rsp.ccode), ccText(rsp.ccode) });
    return false;
}

fn uploadFirmware(intf: *Intf, ctx: *Upgrade, record: Record, option: c_int, cold_reset: *bool) bool {
    const id = record.component;
    ctx.component = id;
    const ver = &gVersionInfo[id];
    var mode: c_int = target_ver | image_ver;
    if (ver.rollbackSupported != 0) mode |= rollback_ver;
    if (option & debug_mode != 0) {
        var description: [22]u8 = .{0} ** 22;
        @memcpy(description[0..21], &record.description);
        _ = c.printf("\n\n Comp ID : %d\t [%-20s]\n", @as(c_int, id), &description);
    } else {
        displayVersion(mode, ver, false);
    }
    if (ctx.mask & (@as(u8, 1) << @intCast(id)) == 0) {
        displayUpgrade(true, 0, 0, 0);
        if (option & compare_mode != 0 and !bit(ctx.properties[id], 3)) {
            _ = c.printf("|    |Comparison isn't supported for given component.                        |\n");
        }
        return true;
    }
    if (c.verbose != 0) log.print(notice, "Do not skip %d", .{@as(c_int, id)});
    displayUpgrade(false, 0, 1, 0);
    const max_request: usize = c.ipmi_intf_get_max_request_data_size(@ptrCast(intf));
    if (max_request <= 2) {
        log.print(err, "Maximum request size is too small to send a upload request.", .{});
        return false;
    }
    const request = std.heap.c_allocator.alloc(u8, max_request) catch {
        log.print(err, "ipmitool: malloc failure", .{});
        return false;
    };
    defer std.heap.c_allocator.free(request);
    request[0] = 0;
    request[1] = 0;
    if (!action(intf, record.components, if (option & compare_mode != 0) 3 else 2, ctx)) {
        displayUpgrade(true, 0, 0, 0);
        return false;
    }
    if (ver.coldResetRequired != 0) cold_reset.* = true;
    var chunk_size: usize = max_request - 2;
    var size_known = false;
    var total_sent: usize = 0;
    var display_size: usize = record.payload.len;
    var section_start: usize = 0;
    var section_length: usize = record.payload.len;
    var position: usize = 0;
    const transfer_limit = std.math.mul(usize, record.payload.len, 3) catch std.math.maxInt(usize);
    const started = c.time(null);
    while (position < section_start + section_length) {
        const count = @min(chunk_size, section_start + section_length - position);
        @memcpy(request[2 .. 2 + count], record.payload[position .. position + count]);
        const outcome = uploadBlock(intf, request[0 .. 2 + count], ctx);
        switch (outcome) {
            .resize => {
                if (size_known or chunk_size == 0) {
                    log.print(notice, "\n Error in Upload FIRMWARE command [rc=%d]\n", .{@as(c_int, 1)});
                    log.print(notice, "\n TotalSent:0x%x ", .{@as(c_uint, @intCast(total_sent))});
                    return false;
                }
                if (isLan(intf) and chunk_size > 8) {
                    chunk_size -= 8;
                } else {
                    chunk_size -= 1;
                }
                log.print(log.Level.info, "Trying reduced buffer length: %d", .{@as(c_int, @intCast(chunk_size))});
                if (chunk_size == 0) return false;
            },
            .retry => {},
            .failed => {
                _ = c.fflush(c.stdout);
                log.print(notice, "\n Error in Upload FIRMWARE command [rc=%d]\n", .{@as(c_int, -1)});
                log.print(notice, "\n TotalSent:0x%x ", .{@as(c_uint, @intCast(total_sent))});
                return false;
            },
            .ok => |next| {
                size_known = true;
                if (next.offset > record.payload.len or next.length > record.payload.len - next.offset) {
                    log.print(notice, "\n Error in Upload FIRMWARE command [rc=%d]\n", .{@as(c_int, 0)});
                    log.print(notice, "\n TotalSent:0x%x Img offset:0x%x  Blk length:0x%x  Fwlen:0x%x\n", .{ @as(c_uint, @intCast(total_sent)), @as(c_uint, @intCast(next.offset)), @as(c_uint, @intCast(next.length)), @as(c_uint, @intCast(record.payload.len)) });
                    return false;
                }
                total_sent += count;
                if (total_sent > transfer_limit) {
                    log.print(notice, "\n Error in Upload FIRMWARE command [rc=%d]\n", .{@as(c_int, -1)});
                    return false;
                }
                if (next.offset != 0) {
                    if (next.length == 0) return false;
                    section_start = next.offset;
                    section_length = next.length;
                    position = section_start;
                    if (display_size == record.payload.len) display_size = next.length + total_sent;
                } else {
                    position += count;
                }
                const elapsed: i64 = c.time(null) - started;
                if (option & debug_mode != 0) {
                    _ = c.fflush(c.stdout);
                    _ = c.printf(" Blk Num : %02x        Bytes : %05x ", @as(c_uint, request[1]), @as(c_uint, @intCast(total_sent)));
                    if (next.offset != 0 or next.length != 0)
                        _ = c.printf("\n--> ImgOff : %x BlkLen : %x\n", @as(c_uint, @intCast(next.offset)), @as(c_uint, @intCast(next.length)));
                    if (display_size == total_sent) {
                        _ = c.printf("\n Time Taken %02ld:%02ld\n\n", @as(c_long, @intCast(@divTrunc(elapsed, 60))), @as(c_long, @intCast(@mod(elapsed, 60))));
                    }
                } else {
                    displayUpgrade(false, total_sent, display_size, elapsed);
                }
                request[1] +%= 1;
            },
        }
    }
    return finishUpload(intf, id, total_sent, ctx, option);
}

fn upgradeStage(intf: *Intf, ctx: *Upgrade, option: c_int) bool {
    var it = records(ctx);
    displayUpgradeHeader();
    var cold_reset = false;
    var ok = true;
    while (ok) {
        const record = (it.next() catch {
            ok = false;
            break;
        }) orelse break;
        switch (record.kind) {
            0, 1 => {
                if (option & compare_mode == 0) {
                    const mask = record.components & ctx.mask;
                    if (mask != 0) ok = action(intf, mask, record.kind, ctx);
                }
            },
            2 => ok = uploadFirmware(intf, ctx, record, option, &cold_reset),
            else => unreachable,
        }
    }
    displayLine('-', 79);
    _ = c.fflush(c.stdout);
    log.print(notice, "(*) Component requires Payload Cold Reset", .{});
    return ok;
}

fn activationStage(intf: *Intf, ctx: *Upgrade) bool {
    _ = c.printf("    ");
    _ = c.fflush(c.stdout);
    var ok = activate(intf, false, ctx);
    if (ok and (bit(ctx.target.flags, 0) or bit(ctx.header.flags, 7))) {
        if (querySelftest(intf, ctx)) |result| {
            if (result[0] != 0x55) {
                log.print(notice, "    Self test failed:", .{});
                log.print(notice, "    Result1 = %x", .{@as(c_uint, result[0])});
                log.print(notice, "    Result2 = %x", .{@as(c_uint, result[1])});
                ok = false;
            }
        } else {
            log.print(notice, "    Self test failed.", .{});
            ok = false;
        }
    }
    if (!ok and bit(ctx.target.flags, 1) and ctx.properties[ctx.component] & 3 != 0) {
        log.print(notice, "    Getting rollback status...", .{});
        _ = c.fflush(c.stdout);
        ok = rollbackStatus(intf, ctx);
    }
    return ok;
}

fn upgrade(intf: *Intf, filename: [*:0]u8, activate_after: bool, selected: c_int, option: c_int) c_int {
    const image = readImage(filename) orelse {
        if (option & view_mode != 0) {
            log.print(notice, " ", .{});
        } else if (option & compare_mode != 0) {
            log.print(notice, "Firmware comparison procedure failed\n", .{});
        } else {
            log.print(notice, "Firmware upgrade procedure failed\n", .{});
        }
        return -1;
    };
    defer std.heap.c_allocator.free(image);
    _ = c.printf("Validating firmware image integrity...");
    _ = c.fflush(c.stdout);
    const header = validateImage(image) orelse {
        if (option & view_mode != 0) log.print(notice, " ", .{}) else if (option & compare_mode != 0)
            log.print(notice, "Firmware comparison procedure failed\n", .{})
        else
            log.print(notice, "Firmware upgrade procedure failed\n", .{});
        return -1;
    };
    var ctx: Upgrade = .{ .image = image, .header = header };
    _ = c.printf("OK\n");
    _ = c.fflush(c.stdout);
    _ = c.printf("Performing preparation stage...");
    _ = c.fflush(c.stdout);
    var ok = preparation(intf, &ctx, option);
    if (ok) {
        _ = c.printf("OK\n");
        _ = c.fflush(c.stdout);
        if (option & view_mode != 0) {
            log.print(notice, "\nComparing Target & Image File version", .{});
        } else if (option & compare_mode != 0) {
            log.print(notice, "\nPerforming upload for compare stage:", .{});
        } else {
            log.print(notice, "\nPerforming upgrade stage:", .{});
        }
        ok = precheck(&ctx, selected, option);
        if (ok and option & view_mode == 0) {
            if (c.verbose != 0) _ = c.printf("Component update mask : 0x%02x\n", @as(c_uint, ctx.mask));
            ok = upgradeStage(intf, &ctx, option);
        }
    }
    if (ok and activate_after) {
        if (ctx.mask != 0) {
            log.print(notice, "Performing activation stage: ", .{});
            ok = activationStage(intf, &ctx);
        } else {
            log.print(notice, "No components updated. Skipping activation stage.\n", .{});
        }
    }
    if (ok) {
        if (option & view_mode != 0) {
            log.print(notice, " ", .{});
        } else if (option & compare_mode != 0) {
            log.print(notice, "\nFirmware comparison procedure complete\n", .{});
        } else {
            log.print(notice, "\nFirmware upgrade procedure successful\n", .{});
        }
    } else if (option & view_mode != 0) {
        log.print(notice, " ", .{});
    } else if (option & compare_mode != 0) {
        log.print(notice, "Firmware comparison procedure failed\n", .{});
    } else {
        log.print(notice, "Firmware upgrade procedure failed\n", .{});
    }
    return if (ok) 0 else -1;
}

fn printUsage() void {
    const lines = [_][*:0]const u8{
        "help                    - This help menu.",
        "",
        "check                   - Check the target information.",
        "check <file>            - If the user is unsure of what update is going to be ",
        "                          This will display the existing target version and",
        "                          image version on the screen",
        "",
        "upgrade <file> [component x...] [force] [activate]",
        "                        - Copies components from a valid HPM.1 image to the target.",
        "                          If one or more components specified by \"component\",",
        "                          only the specified components are copied.",
        "                          Otherwise, all the image components are copied.",
        "                          Before copy, each image component undergoes a version check",
        "                          and can be skipped if the target component version",
        "                          is the same or more recent.",
        "                          Use \"force\" to bypass the version check results.",
        "                          Make sure to check the versions first using the",
        "                          \"check <file>\" command.",
        "                          If \"activate\" is specified, the newly uploaded firmware",
        "                          is activated.",
        "upgstatus               - Returns the status of the last long duration command.",
        "",
        "compare <file>          - Perform \"Comparison of the Active Copy\" action for all the",
        "                          components present in the file.",
        "compare <file> component x - Compare only component <x> from the given <file>",
        "activate                - Activate the newly uploaded firmware.",
        "activate norollback     - Activate the newly uploaded firmware but inform",
        "                          the target to not automatically rollback if ",
        "                          the upgrade fails.",
        "",
        "targetcap               - Get the target upgrade capabilities.",
        "",
        "compprop <id> <prop>    - Get specified component properties from the target.",
        "                          Valid component <id>: 0-7 ",
        "                          Properties <prop> can be one of the following: ",
        "                          0- General properties",
        "                          1- Current firmware version",
        "                          2- Description string",
        "                          3- Rollback firmware version",
        "                          4- Deferred firmware version",
        "",
        "abort                   - Abort the on-going firmware upgrade.",
        "",
        "rollback                - Performs a manual rollback on the IPM Controller.",
        "                          firmware",
        "rollbackstatus          - Query the rollback status.",
        "",
        "selftestresult          - Query the self test results.\n",
    };
    for (lines) |line| log.print(notice, "%s", .{line});
}

fn argument(argv: [*c][*c]u8, index: usize) ?[*:0]u8 {
    const value = argv[index];
    if (value == null) return null;
    return @ptrCast(value);
}

fn equal(arg: ?[*:0]u8, text: []const u8) bool {
    return if (arg) |ptr| std.mem.eql(u8, std.mem.span(ptr), text) else false;
}

fn parseComponent(arg: ?[*:0]u8, into: *c_int) bool {
    if (arg == null or c.str2int(arg, into) != 0 or into.* < 0 or into.* > 8) {
        log.print(err, "Given Component ID '%s' is invalid.", .{arg orelse @as([*:0]const u8, "(null)")});
        log.print(err, "Valid Component ID is: <0..7>", .{});
        return false;
    }
    return true;
}

fn run(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    log.print(log.Level.debug, "ipmi_hpmfwupg_main()", .{});
    log.print(notice, "\nPICMG HPM.1 Upgrade Agent %d.%d.%d: \n", .{ @as(c_int, 1), @as(c_int, 0), @as(c_int, 9) });
    if (argc < 1 or argv == null) {
        log.print(err, "Not enough parameters given.", .{});
        printUsage();
        return -1;
    }
    const cmd = argument(argv, 0);
    if (equal(cmd, "help")) {
        printUsage();
        return 0;
    }
    if (equal(cmd, "check")) {
        if (argc < 2 or argument(argv, 1) == null) return if (targetCheck(intf, view_mode)) 0 else -1;
        if (!targetCheck(intf, 0)) return -1;
        return upgrade(intf, argument(argv, 1).?, false, 0, view_mode);
    }
    if (equal(cmd, "upgrade") or equal(cmd, "compare")) {
        const comparing = equal(cmd, "compare");
        var selected: c_int = 0;
        var option: c_int = if (comparing) compare_mode else 0;
        var activate_after = false;
        var i: usize = 1;
        while (i < @as(usize, @intCast(argc))) : (i += 1) {
            const arg = argument(argv, i);
            if (!comparing and equal(arg, "activate")) activate_after = true;
            if (!comparing and equal(arg, "force")) option |= force_mode;
            if (equal(arg, "debug")) option |= debug_mode;
            if (equal(arg, "component")) {
                if (i + 1 >= @as(usize, @intCast(argc))) {
                    log.print(notice, "No component Id provided\n", .{});
                    return -1;
                }
                var id: c_int = 0;
                if (!parseComponent(argument(argv, i + 1), &id)) return -1;
                if (c.verbose != 0) log.print(notice, "Component Id %d provided", .{id});
                selected |= @as(c_int, 1) << @intCast(id);
            }
        }
        if (!targetCheck(intf, 0)) return -1;
        if (argc < 2) {
            log.print(err, "No image file provided.", .{});
            return -1;
        }
        return upgrade(intf, argument(argv, 1) orelse return -1, activate_after, selected, option);
    }
    if (equal(cmd, "activate")) {
        return if (activate(intf, argc == 2 and equal(argument(argv, 1), "norollback"), null)) 0 else -1;
    }
    if (argc == 1 and equal(cmd, "targetcap")) {
        c.verbose += 1;
        return if (getCapabilities(intf) != null) 0 else -1;
    }
    if (argc == 3 and equal(cmd, "compprop")) {
        var id: u8 = 0;
        var selector: u8 = 0;
        if (c.str2uchar(argument(argv, 1), &id) != 0 or id > 7) {
            log.print(err, "Given Component ID '%s' is invalid.", .{argument(argv, 1)});
            log.print(err, "Valid Component ID is: <0..7>", .{});
            return -1;
        }
        if (c.str2uchar(argument(argv, 2), &selector) != 0 or selector > 4) {
            log.print(err, "Given Properties selector '%s' is invalid.", .{argument(argv, 2)});
            log.print(err, "Valid Properties selector is: <0..4>", .{});
            return -1;
        }
        c.verbose += 1;
        return if (getProperty(intf, id, selector) != null) 0 else -1;
    }
    if (argc == 1 and equal(cmd, "abort")) {
        c.verbose += 1;
        return if (abortUpgrade(intf)) 0 else -1;
    }
    if (argc == 1 and equal(cmd, "upgstatus")) {
        c.verbose += 1;
        return if (getStatus(intf, null, false) != null) 0 else -1;
    }
    if (argc == 1 and equal(cmd, "rollback")) {
        c.verbose += 1;
        return if (manualRollback(intf)) 0 else -1;
    }
    if (argc == 1 and equal(cmd, "rollbackstatus")) {
        c.verbose += 1;
        return if (rollbackStatus(intf, null)) 0 else -1;
    }
    if (argc == 1 and equal(cmd, "selftestresult")) {
        c.verbose += 1;
        return if (querySelftest(intf, null) != null) 0 else -1;
    }
    log.print(err, "Invalid HPM command: %s", .{cmd});
    printUsage();
    return -1;
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(run), @TypeOf(c.ipmi_hpmfwupg_main));
    @export(&run, .{ .name = "ipmi_hpmfwupg_main", .linkage = .strong });
    @export(&gVersionInfo, .{ .name = "gVersionInfo", .linkage = .strong });
}

test "HPM image checksums and little-endian size boundaries" {
    try std.testing.expectEqual(@as(u16, 0xffff), le16(&.{ 0xff, 0xff }));
    try std.testing.expectEqual(@as(u32, 0xffffffff), le32(&.{ 0xff, 0xff, 0xff, 0xff }));
    try std.testing.expectEqual(@as(u8, 0), checksum(&.{ 0x01, 0x01, 0xfe }));
}

test "HPM responses reject negative, truncated and oversized lengths" {
    var rsp = std.mem.zeroes(Response);
    rsp.data_len = -1;
    try std.testing.expect(responseData(&rsp) == null);
    rsp.data_len = ipmi.buf_size + 1;
    try std.testing.expect(responseData(&rsp) == null);
    rsp.data_len = 2;
    try std.testing.expectEqual(@as(usize, 2), responseData(&rsp).?.len);
}

test "HPM validated header cannot authorize a truncated firmware payload" {
    var image: [35 + 3 + 31 + 16]u8 = .{0} ** (35 + 3 + 31 + 16);
    @memcpy(image[0..8], "PICMGFWU");
    image[20] = 1;
    image[34] = 0 -% checksum(image[0..35]);
    image[35] = 2;
    image[36] = 1;
    image[37] = 0xfd;
    @memset(image[65..69], 0xff);
    std.crypto.hash.Md5.hash(image[0 .. image.len - 16], @ptrCast(&image[image.len - 16]), .{});
    const header = validateImage(&image) orelse return error.InvalidHeader;
    var it: Records = .{ .image = &image, .pos = header.first_record, .end = image.len - 16 };
    try std.testing.expectError(error.Invalid, it.next());

    // A checksum-valid image with just two bytes of an action header must
    // fail before reading the MD5 bytes as if they were an action checksum.
    var short: [35 + 2 + 16]u8 = .{0} ** (35 + 2 + 16);
    @memcpy(short[0..35], image[0..35]);
    @memcpy(short[35..37], image[35..37]);
    std.crypto.hash.Md5.hash(short[0 .. short.len - 16], @ptrCast(&short[short.len - 16]), .{});
    const short_header = validateImage(&short) orelse return error.InvalidHeader;
    var short_it: Records = .{ .image = &short, .pos = short_header.first_record, .end = short.len - 16 };
    try std.testing.expectError(error.Invalid, short_it.next());
}
