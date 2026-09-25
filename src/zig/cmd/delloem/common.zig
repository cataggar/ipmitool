const std = @import("std");
pub const c = @import("ipmi_c");
pub const Intf = @import("../../intf/intf.zig").Intf;
pub const ipmi = @import("../../core/ipmi.zig");
pub const Request = ipmi.Request;
pub const Response = ipmi.Response;
pub const log = @import("../../util/log.zig");

pub var imc_type: u8 = 0x08;
pub var idrac_flag: u8 = 0;
pub var idrac_all: u8 = 0;
pub var idrac_12_13: u8 = 0;
pub var power_cap_settable: u8 = 0;
pub var power_cap_enabled: u8 = 0;
pub var lcd_mode: [13]u8 = .{0} ** 13;
pub var power_headroom: [4]u8 = .{0} ** 4;

pub fn arg(argv: [*c][*c]u8, argc: c_int, index: usize) ?[*:0]u8 {
    if (index >= @as(usize, @intCast(@max(argc, 0)))) return null;
    const ptr = argv[index];
    return if (ptr == null) null else @ptrCast(ptr);
}

pub fn eq(a: ?[*:0]const u8, b: []const u8) bool {
    const p = a orelse return false;
    return std.mem.eql(u8, std.mem.span(p), b);
}

pub fn notice(lines: []const []const u8) void {
    for (lines) |line| log.print(log.Level.notice, "%.*s", .{ @as(c_int, @intCast(line.len)), line.ptr });
}

pub fn cc(code: u8) [*c]const u8 {
    return c.val2str(code, c.completion_code_vals);
}

pub fn short(name: [*:0]const u8) c_int {
    log.print(log.Level.err, "Short %s response", .{name});
    return -1;
}

pub fn bytes(rsp: *const Response, need: usize) ?[]const u8 {
    if (rsp.data_len < 0) return null;
    const n: usize = @intCast(rsp.data_len);
    if (n < need or n > rsp.data.len) return null;
    return rsp.data[0..n];
}

pub fn send(intf: *Intf, netfn: u6, cmd: u8, data: []const u8) ?*Response {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn;
    req.msg.cmd = cmd;
    req.msg.data_len = @intCast(data.len);
    req.msg.data = if (data.len == 0) null else @ptrCast(@constCast(data.ptr));
    return intf.sendrecv.?(intf, &req);
}

pub fn getSys(intf: *Intf, selector: u8, block: u8, out: []u8) c_int {
    if (c.verbose > 1) _ = c.printf("getsysinfo: %.2x/%.2x/%.2x\n", @as(c_int, selector), @as(c_int, block), @as(c_int, 0));
    const rsp = send(intf, 0x06, 0x59, &.{ 0, selector, block, 0 }) orelse return -1;
    if (rsp.ccode != 0) return rsp.ccode;
    if (bytes(rsp, out.len)) |data| {
        @memcpy(out, data[0..out.len]);
        return 0;
    }
    return -2;
}

pub fn setSys(intf: *Intf, data: []const u8) c_int {
    const rsp = send(intf, 0x06, 0x58, data) orelse return -1;
    return rsp.ccode;
}

pub fn validator(intf: *Intf) void {
    var data: [11]u8 = undefined;
    if (getSys(intf, 0xdd, 2, &data) != 0) return;
    idrac_all = 0;
    idrac_12_13 = 0;
    imc_type = data[10];
    switch (imc_type) {
        0x0a, 0x0b, 0x0d, 0x0e => {
            idrac_flag = 1;
            idrac_all = 1;
        },
        0x10, 0x11 => {
            idrac_flag = 2;
            idrac_all = 1;
            idrac_12_13 = 1;
        },
        0x20, 0x21, 0x22 => {
            idrac_flag = 3;
            idrac_all = 1;
            idrac_12_13 = 1;
        },
        else => idrac_flag = 0,
    }
}

pub fn license(code: u8) bool {
    if (idrac_12_13 == 0 or code != 0x6f) return false;
    log.print(log.Level.err, "FM001 : A required license is missing or expired", .{});
    return true;
}

pub fn le16(data: []const u8) u16 {
    return std.mem.readInt(u16, data[0..2], .little);
}

pub fn le32(data: []const u8) u32 {
    return std.mem.readInt(u32, data[0..4], .little);
}

pub fn put16(data: []u8, val: u16) void {
    std.mem.writeInt(u16, data[0..2], val, .little);
}

pub fn put32(data: []u8, val: u32) void {
    std.mem.writeInt(u32, data[0..4], val, .little);
}
