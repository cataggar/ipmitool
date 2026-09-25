// Copyright (c) 2018 Quanta Computer Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// Redistribution of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//
// Redistribution in binary form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// Neither the name of Quanta Computer Inc. or the names of
// contributors may be used to endorse or promote products derived
// from this software without specific prior written permission.
//
// This software is provided "AS IS," without a warranty of any kind.
// ALL EXPRESS OR IMPLIED CONDITIONS, REPRESENTATIONS AND WARRANTIES,
// INCLUDING ANY IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A
// PARTICULAR PURPOSE OR NON-INFRINGEMENT, ARE HEREBY EXCLUDED.
// Quanta Computer Inc. AND ITS LICENSORS SHALL NOT BE LIABLE
// FOR ANY DAMAGES SUFFERED BY LICENSEE AS A RESULT OF USING, MODIFYING
// OR DISTRIBUTING THIS SOFTWARE OR ITS DERIVATIVES.  IN NO EVENT WILL
// Quanta Computer Inc. OR ITS LICENSORS BE LIABLE
// FOR ANY LOST REVENUE, PROFIT OR DATA,
// OR FOR DIRECT, INDIRECT, SPECIAL, CONSEQUENTIAL, INCIDENTAL OR
// PUNITIVE DAMAGES, HOWEVER CAUSED AND REGARDLESS OF THE THEORY OF
// LIABILITY, ARISING OUT OF THE USE OF OR INABILITY TO USE THIS SOFTWARE,
// EVEN IF SUN HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.
//! Quanta platform identification and OEM memory-event descriptions.
//!
//! Replaces `lib/ipmi_quantaoem.c`. The two exported helpers are called by
//! both the C and Zig SEL implementations; the returned description is
//! allocated with libc because the caller frees it with `free()`.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");

const desc_size: usize = 128;
const magic = [4]u8{ 0x4c, 0x1c, 0x00, 0x02 };

/// `oem_qct_get_platform_id()`. A zero-length successful response reads the
/// first byte of the interface's persistent response buffer, just as C does.
fn getPlatformId(intf: *Intf) callconv(.c) c.qct_platform_t {
    var data = magic;
    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = @intCast(c.OEM_QCT_NETFN);
    req.msg.cmd = @intCast(c.OEM_QCT_GET_INFO);
    req.msg.data = &data;
    req.msg.data_len = data.len;

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(log.Level.err, "Get Platform ID command failed");
        return 0;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Get Platform ID command failed: %#x %s",
            @as(c_int, rsp.ccode),
            c.val2str(rsp.ccode, c.completion_code_vals),
        );
        return 0;
    }
    const platform_id = rsp.data[0];
    c.lprintf(log.Level.debug, "Platform ID: %hhx", @as(c_int, platform_id));
    return @intCast(platform_id);
}

/// `oem_qct_get_evt_desc()`. Non-Quanta event types don't issue IPMI requests.
fn getEvtDesc(intf: *Intf, rec: ?*c.struct_sel_event_record) callconv(.c) [*c]u8 {
    const bytes: [*]const u8 = @ptrCast(rec.?);
    const data_offset: usize = c.ABI_OFFSETOF_sel_event_record__std__event_data;
    if (bytes[data_offset - 1] & 0x7f != 0x6f) return null;

    const desc: [*c]u8 = @ptrCast(c.malloc(desc_size));
    if (desc == null) {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return null;
    }
    _ = c.memset(desc, 0, desc_size);

    if (bytes[c.ABI_OFFSETOF_sel_event_record__std__sensor_type] != c.SENSOR_TYPE_MEMORY) {
        c.free(desc);
        return null;
    }

    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = @intCast(c.IPMI_NETFN_APP);
    req.msg.cmd = @intCast(c.BMC_GET_DEVICE_ID);
    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(log.Level.err, " Error getting system info");
        c.free(desc);
        return null;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            " Error getting system info: %s",
            c.val2str(rsp.ccode, c.completion_code_vals),
        );
        c.free(desc);
        return null;
    }

    if (getPlatformId(intf) == c.OEM_QCT_PLATFORM_PURLEY) {
        const data = bytes[data_offset + 2];
        _ = c.snprintf(
            desc,
            desc_size,
            "CPU%d_%c%d",
            @as(c_int, (data >> 6) & 0x03),
            @as(c_int, 0x41 + ((data >> 3) & 0x07)),
            @as(c_int, data & 0x07),
        );
    }
    return desc;
}

pub fn exportSymbols() void {
    comptime {
        abi.assertCallSignature(@TypeOf(getPlatformId), @TypeOf(c.oem_qct_get_platform_id));
        abi.assertCallSignature(@TypeOf(getEvtDesc), @TypeOf(c.oem_qct_get_evt_desc));
        @export(&getPlatformId, .{ .name = "oem_qct_get_platform_id", .linkage = .strong });
        @export(&getEvtDesc, .{ .name = "oem_qct_get_evt_desc", .linkage = .strong });
    }
}
