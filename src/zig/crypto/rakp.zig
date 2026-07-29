//! The RMCP+ / RAKP hash input buffers from `src/plugins/lanplus/lanplus_crypt.c`.
//!
//! These are separated from the exported wrappers so the byte layout — which is
//! the part a BMC actually sees, and the part that is easy to get subtly wrong —
//! can be checked against vectors captured from the C build without linking any
//! C.
//!
//! Every multi-byte field is defined by the spec as least significant byte
//! first, so the session ids are written little endian on every host.  The 16
//! byte fields are copied straight through on little endian hosts and
//! *reversed* on big endian ones; that reversal is not something the spec asks
//! for, but it is what the C does, so it is reproduced here.

const std = @import("std");
const builtin = @import("builtin");

/// A 16 byte spec field, laid out the way `lanplus_crypt.c` lays it out.
fn writeArray16(out: *[16]u8, value: *const [16]u8) void {
    if (builtin.target.cpu.arch.endian() == .big) {
        for (out, 0..) |*b, i| b.* = value[16 - 1 - i];
    } else {
        out.* = value.*;
    }
}

/// A session id, always least significant byte first.
fn writeSessionId(out: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, out, value, .little);
}

/// Inputs shared by the three key-derivation buffers.
pub const Inputs = struct {
    /// SIDm: remote console session id.
    console_id: u32 = 0,
    /// SIDc: BMC session id.
    bmc_id: u32 = 0,
    /// Rm: remote console random number.
    console_rand: [16]u8 = @splat(0),
    /// Rc: BMC random number.
    bmc_rand: [16]u8 = @splat(0),
    /// GUIDc: BMC GUID.
    bmc_guid: [16]u8 = @splat(0),
    /// ROLEm: the requested privilege level byte, already masked by the caller.
    role: u8 = 0,
    /// UNAMEm.
    username: []const u8 = &.{},
};

/// Length of the RAKP 2 key exchange authentication code input.
pub fn rakp2Length(username_len: usize) usize {
    return 4 + 4 + 16 + 16 + 16 + 1 + 1 + username_len;
}

/// Length of the RAKP 3 integrity check value input.
pub fn rakp3Length(username_len: usize) usize {
    return 16 + 4 + 1 + 1 + username_len;
}

/// Length of the RAKP 4 integrity check value input.
pub const rakp4_length = 16 + 4 + 16;

/// Length of the session integrity key input.
pub fn sikLength(username_len: usize) usize {
    return 16 + 16 + 1 + 1 + username_len;
}

/// SIDm | SIDc | Rm | Rc | GUIDc | ROLEm | ULENGTHm | UNAMEm.
pub fn rakp2(out: []u8, in: Inputs) void {
    std.debug.assert(out.len == rakp2Length(in.username.len));
    writeSessionId(out[0..4], in.console_id);
    writeSessionId(out[4..8], in.bmc_id);
    writeArray16(out[8..24], &in.console_rand);
    writeArray16(out[24..40], &in.bmc_rand);
    writeArray16(out[40..56], &in.bmc_guid);
    out[56] = in.role;
    out[57] = @intCast(in.username.len);
    @memcpy(out[58..], in.username);
}

/// Rc | SIDm | ROLEm | ULENGTHm | UNAMEm.
pub fn rakp3(out: []u8, in: Inputs) void {
    std.debug.assert(out.len == rakp3Length(in.username.len));
    writeArray16(out[0..16], &in.bmc_rand);
    writeSessionId(out[16..20], in.console_id);
    out[20] = in.role;
    out[21] = @intCast(in.username.len);
    @memcpy(out[22..], in.username);
}

/// Rm | SIDc | GUIDc.
pub fn rakp4(out: *[rakp4_length]u8, in: Inputs) void {
    writeArray16(out[0..16], &in.console_rand);
    writeSessionId(out[16..20], in.bmc_id);
    writeArray16(out[20..36], &in.bmc_guid);
}

/// Rm | Rc | ROLEm | ULENGTHm | UNAMEm.
pub fn sik(out: []u8, in: Inputs) void {
    std.debug.assert(out.len == sikLength(in.username.len));
    writeArray16(out[0..16], &in.console_rand);
    writeArray16(out[16..32], &in.bmc_rand);
    out[32] = in.role;
    out[33] = @intCast(in.username.len);
    @memcpy(out[34..], in.username);
}

/// `CONST_1`, hashed under the SIK to produce K1.
pub const const_1: [20]u8 = @splat(0x01);

/// `CONST_2`, hashed under the SIK to produce K2.
pub const const_2: [20]u8 = @splat(0x02);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_inputs: Inputs = .{
    .console_id = 0xa0a1a2a3,
    .bmc_id = 0xb0b1b2b3,
    .console_rand = .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    },
    .bmc_rand = .{
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    },
    .bmc_guid = .{
        0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
        0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
    },
    .role = 0x14,
    .username = "admin",
};

test "rakp2 input layout" {
    var buffer: [128]u8 = undefined;
    const out = buffer[0..rakp2Length(test_inputs.username.len)];
    rakp2(out, test_inputs);

    try std.testing.expectEqual(@as(usize, 63), out.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xa3, 0xa2, 0xa1, 0xa0 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0xb3, 0xb2, 0xb1, 0xb0 }, out[4..8]);
    try std.testing.expectEqualSlices(u8, &test_inputs.console_rand, out[8..24]);
    try std.testing.expectEqualSlices(u8, &test_inputs.bmc_rand, out[24..40]);
    try std.testing.expectEqualSlices(u8, &test_inputs.bmc_guid, out[40..56]);
    try std.testing.expectEqual(@as(u8, 0x14), out[56]);
    try std.testing.expectEqual(@as(u8, 5), out[57]);
    try std.testing.expectEqualStrings("admin", out[58..]);
}

test "rakp3 input layout" {
    var buffer: [128]u8 = undefined;
    const out = buffer[0..rakp3Length(test_inputs.username.len)];
    rakp3(out, test_inputs);

    try std.testing.expectEqual(@as(usize, 27), out.len);
    try std.testing.expectEqualSlices(u8, &test_inputs.bmc_rand, out[0..16]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa3, 0xa2, 0xa1, 0xa0 }, out[16..20]);
    try std.testing.expectEqual(@as(u8, 0x14), out[20]);
    try std.testing.expectEqual(@as(u8, 5), out[21]);
    try std.testing.expectEqualStrings("admin", out[22..]);
}

test "rakp4 input layout" {
    var out: [rakp4_length]u8 = undefined;
    rakp4(&out, test_inputs);

    try std.testing.expectEqualSlices(u8, &test_inputs.console_rand, out[0..16]);
    try std.testing.expectEqualSlices(u8, &.{ 0xb3, 0xb2, 0xb1, 0xb0 }, out[16..20]);
    try std.testing.expectEqualSlices(u8, &test_inputs.bmc_guid, out[20..36]);
}

test "sik input layout" {
    var buffer: [128]u8 = undefined;
    const out = buffer[0..sikLength(test_inputs.username.len)];
    sik(out, test_inputs);

    try std.testing.expectEqual(@as(usize, 39), out.len);
    try std.testing.expectEqualSlices(u8, &test_inputs.console_rand, out[0..16]);
    try std.testing.expectEqualSlices(u8, &test_inputs.bmc_rand, out[16..32]);
    try std.testing.expectEqual(@as(u8, 0x14), out[32]);
    try std.testing.expectEqual(@as(u8, 5), out[33]);
    try std.testing.expectEqualStrings("admin", out[34..]);
}

test "an empty user name contributes only its length" {
    var buffer: [128]u8 = undefined;
    var inputs = test_inputs;
    inputs.username = "";

    const out = buffer[0..rakp2Length(0)];
    rakp2(out, inputs);
    try std.testing.expectEqual(@as(usize, 58), out.len);
    try std.testing.expectEqual(@as(u8, 0), out[57]);
}
