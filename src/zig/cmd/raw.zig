//! Port of `lib/ipmi_raw.c`: the `raw`, `i2c` and `spd` commands plus the
//! shared I2C Master Write-Read helper.
//!
//! Selected with `zig build -Dzig-modules=raw`, which drops `lib/ipmi_raw.c`
//! from the compile and links this module instead.  `src/ipmitool.c` reaches
//! the three `*_main` entry points through `ipmitool_cmd_list[]` and
//! `lib/ipmi_gendev.c` calls `ipmi_master_write_read()` directly; both link
//! against this file unchanged and unaware.
//!
//! Three things are worth knowing before reading on:
//!
//! * **Formatting and parsing stay in libc.**  `printf`, `lprintf`, `printbuf`
//!   and `sscanf` are called through the `ipmi_c` bridge rather than
//!   reimplemented, for the same reason `util/helper.zig` does it: `%2.2x`,
//!   `%02Xh` and what exactly `sscanf("%u")` accepts are observable, and the
//!   acceptance criterion for this port is that the bytes ipmitool writes -
//!   and the IPMI request bytes it sends - do not change.
//! * **`netfn` and `lun` are bit fields.**  `struct ipmi_rq` packs `netfn:6`
//!   and `lun:2` into one byte, so `raw 0xff ...` reaches the wire as net
//!   function 0x3f and `-l 7` as LUN 3.  `core/ipmi.zig` mirrors that with
//!   `NetFnLun`, and the assignments below truncate exactly as C's do.
//! * **The exports are gathered in `exportSymbols()`**, which
//!   `src/zig/exports.zig` invokes at comptime only when `raw` is selected;
//!   see the note there.
//!
//! Allocation: none.  Every buffer here is a local, exactly as in C.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const log = @import("../util/log.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;

/// `IPMI_I2C_MASTER_MAX_SIZE`: 64 bytes, the largest single I2C transfer the
/// Master Write-Read command carries.
const i2c_master_max_size: u8 = 0x40;

/// `RAW_SPD_SIZE`: how much of an SPD EEPROM `ipmi_rawspd_main()` reads.
const raw_spd_size = 512;

/// `BUS_KW`.
const bus_kw = "bus=";

/// `CHAN_KW`.
const chan_kw = "chan=";

/// `is_valid_param()`.
///
/// Private, as in C: `lib/ipmi_raw.c` forward-declares it `static` and the
/// definition inherits that internal linkage, so the symbol never escaped the
/// translation unit.
///
/// Returns 0 when `input_param` parses as a `uint8_t`, -1 otherwise.
fn isValidParam(input_param: ?[*:0]const u8, uchr_ptr: *u8, label: ?[*:0]const u8) c_int {
    if (input_param == null or label == null) {
        c.lprintf(log.Level.@"error", "ERROR: NULL pointer passed.");
        return -1;
    }
    if (c.str2uchar(input_param, uchr_ptr) == 0) return 0;

    c.lprintf(log.Level.err, "Given %s \"%s\" is invalid.", label, input_param);
    return -1;
}

/// `ipmi_master_write_read()` - perform an I2C write/read transaction.
///
/// Returns the response, or null when the transfer sizes are out of range, the
/// interface reported no answer, or the BMC returned a completion code.
fn masterWriteRead(
    intf: *Intf,
    bus: u8,
    addr: u8,
    wdata: ?[*]u8,
    wsize: u8,
    rsize: u8,
) callconv(.c) ?*Response {
    var req: Request = undefined;
    var rqdata: [i2c_master_max_size + 3]u8 = undefined;

    if (rsize > i2c_master_max_size) {
        c.lprintf(
            log.Level.err,
            "Master Write-Read: Too many bytes (%d) to read",
            @as(c_int, rsize),
        );
        return null;
    }
    if (wsize > i2c_master_max_size) {
        c.lprintf(
            log.Level.err,
            "Master Write-Read: Too many bytes (%d) to write",
            @as(c_int, wsize),
        );
        return null;
    }

    req = std.mem.zeroes(Request);
    req.msg.netfn_lun = .{ .netfn = ipmi.NetFn.app, .lun = 0 };
    // Master write-read.
    req.msg.cmd = 0x52;
    req.msg.data = &rqdata;
    req.msg.data_len = 3;

    @memset(&rqdata, 0);
    // Channel number, bus id and bus type.
    rqdata[0] = bus;
    // Slave address.
    rqdata[1] = addr;
    // Number of bytes to read.
    rqdata[2] = rsize;

    if (wsize > 0) {
        // Copy in data to write.
        @memcpy(rqdata[3..][0..wsize], wdata.?[0..wsize]);
        req.msg.data_len += wsize;
        c.lprintf(
            log.Level.debug,
            "Writing %d bytes to i2cdev %02Xh",
            @as(c_int, wsize),
            @as(c_uint, addr),
        );
    }

    if (rsize > 0) {
        c.lprintf(
            log.Level.debug,
            "Reading %d bytes from i2cdev %02Xh",
            @as(c_int, rsize),
            @as(c_uint, addr),
        );
    }

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(log.Level.err, "I2C Master Write-Read command failed");
        return null;
    };
    if (rsp.ccode != 0) {
        switch (rsp.ccode) {
            0x81 => c.lprintf(
                log.Level.err,
                "I2C Master Write-Read command failed: Lost Arbitration",
            ),
            0x82 => c.lprintf(
                log.Level.err,
                "I2C Master Write-Read command failed: Bus Error",
            ),
            0x83 => c.lprintf(
                log.Level.err,
                "I2C Master Write-Read command failed: NAK on Write",
            ),
            0x84 => c.lprintf(
                log.Level.err,
                "I2C Master Write-Read command failed: Truncated Read",
            ),
            else => c.lprintf(
                log.Level.err,
                "I2C Master Write-Read command failed: %s",
                c.val2str(rsp.ccode, c.completion_code_vals),
            ),
        }
        return null;
    }

    return rsp;
}

/// `ipmi_rawspd_main()` - read an SPD EEPROM over I2C and hand it to
/// `ipmi_spd_print()`.
fn rawspdMain(intf: *Intf, argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    // Allow to override default.
    var msize: u8 = i2c_master_max_size;
    var channel: u8 = 0;
    var i2cbus: u8 = 0;
    var i2caddr: u8 = 0;
    // C sizes this buffer at exactly RAW_SPD_SIZE, but the loop below steps by
    // `msize` and copies `msize` bytes at each step, so any `maxread` that does
    // not divide 512 makes the last copy run past the end.  The slack keeps the
    // port defined for those inputs; for every `maxread` that divides 512 -
    // which includes the default 64 - the two are byte for byte the same.  See
    // issue #28, which also covers the `maxread == 0` infinite loop below.
    var spd_data: [raw_spd_size + 255]u8 = undefined;
    var i: c_int = 0;

    @memset(spd_data[0..raw_spd_size], 0);

    if (argc < 2 or std.mem.eql(u8, std.mem.span(argv[0]), "help")) {
        c.lprintf(log.Level.notice, "usage: spd <i2cbus> <i2caddr> [channel] [maxread]");
        return 0;
    }

    if (isValidParam(argv[0], &i2cbus, "i2cbus") != 0) return -1;
    if (isValidParam(argv[1], &i2caddr, "i2caddr") != 0) return -1;

    if (argc >= 3) {
        if (isValidParam(argv[2], &channel, "channel") != 0) return -1;
    }

    if (argc >= 4) {
        if (isValidParam(argv[3], &msize, "maxread") != 0) return -1;
    }

    i2cbus = @truncate(((@as(c_uint, channel) & 0xF) << 4) |
        ((@as(c_uint, i2cbus) & 7) << 1) | 1);

    while (i < raw_spd_size) : (i += @as(c_int, msize)) {
        // C passes `(uint8_t *)&i`, i.e. the first byte of the int in memory,
        // which is the low byte of the offset on a little endian target.
        const offset: [*]u8 = @ptrCast(&i);
        const rsp = masterWriteRead(intf, i2cbus, i2caddr, offset, 1, msize) orelse {
            c.lprintf(log.Level.err, "Unable to perform I2C Master Write-Read");
            return -1;
        };

        // `msize` bytes are copied whatever `rsp->data_len` says, so a short
        // response leaves the tail of the previous one in place.
        @memcpy(spd_data[@intCast(i)..][0..msize], rsp.data[0..msize]);
    }

    _ = c.ipmi_spd_print(&spd_data, i);
    return 0;
}

/// `rawi2c_usage()`.
fn rawi2cUsage() void {
    c.lprintf(
        log.Level.notice,
        "usage: i2c [bus=public|# [chan=#] <i2caddr> <read bytes> [write data]",
    );
    c.lprintf(log.Level.notice, "            bus=public is default");
    c.lprintf(
        log.Level.notice,
        "            chan=0 is default, bus= must be specified to use chan=",
    );
    c.lprintf(
        log.Level.notice,
        "            i2caddr is an 8-bit I2C address, only even numbers are accepted",
    );
}

/// `ipmi_rawi2c_main()` - the `i2c` command.
fn rawi2cMain(intf: *Intf, argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    var wdata: [i2c_master_max_size]u8 = undefined;
    var i2caddr: u8 = 0;
    var rsize: u8 = 0;
    var wsize: u8 = 0;
    var rbus: c_uint = 0;
    var bus: u8 = 0;
    var i: c_int = 0;

    // Handle bus= argument.
    if (argc > 2 and std.mem.startsWith(u8, std.mem.span(argv[0]), bus_kw)) {
        i = 1;
        if (std.mem.eql(u8, std.mem.span(argv[0]), bus_kw ++ "public")) {
            bus = 0;
        } else if (c.sscanf(argv[0], bus_kw ++ "%u", &rbus) == 1) {
            bus = @truncate(((rbus & 7) << 1) | 1);
        } else {
            bus = 0;
        }

        // Handle channel= argument; the bus= argument must be supplied first
        // on the command line.
        if (argc > 3 and std.mem.startsWith(u8, std.mem.span(argv[1]), chan_kw)) {
            i = 2;
            if (c.sscanf(argv[1], chan_kw ++ "%u", &rbus) == 1) {
                bus = @truncate(@as(c_uint, bus) | (rbus << 4));
            }
        }
    }

    if ((argc - i) < 2 or std.mem.eql(u8, std.mem.span(argv[0]), "help")) {
        rawi2cUsage();
        return 0;
    } else if (argc - i - 2 > @as(c_int, i2c_master_max_size)) {
        c.lprintf(
            log.Level.err,
            "Raw command input limit (%d bytes) exceeded",
            @as(c_int, i2c_master_max_size),
        );
        return -1;
    }

    if (isValidParam(argv[@intCast(i)], &i2caddr, "i2caddr") != 0) return -1;
    i += 1;
    if (isValidParam(argv[@intCast(i)], &rsize, "read size") != 0) return -1;
    i += 1;

    if (i2caddr == 0 or (i2caddr & 1) != 0) {
        c.lprintf(log.Level.err, "Invalid I2C address");
        rawi2cUsage();
        return -1;
    }

    @memset(&wdata, 0);
    while (i < argc) : (i += 1) {
        var val: u8 = 0;

        if (isValidParam(argv[@intCast(i)], &val, "parameter") != 0) return -1;

        wdata[wsize] = val;
        wsize += 1;
    }

    c.lprintf(
        log.Level.info,
        "RAW I2C REQ (i2caddr=%x readbytes=%d writebytes=%d)",
        @as(c_uint, i2caddr),
        @as(c_int, rsize),
        @as(c_int, wsize),
    );
    c.printbuf(&wdata, @as(c_int, wsize), "WRITE DATA");

    const rsp = masterWriteRead(intf, bus, i2caddr, &wdata, wsize, rsize) orelse {
        c.lprintf(log.Level.err, "Unable to perform I2C Master Write-Read");
        return -1;
    };

    if (wsize > 0) {
        if (c.verbose != 0 or rsize == 0) {
            _ = c.printf(
                "Wrote %d bytes to I2C device %02Xh\n",
                @as(c_int, wsize),
                @as(c_uint, i2caddr),
            );
        }
    }

    if (rsize > 0) {
        if (c.verbose != 0 or wsize == 0) {
            _ = c.printf(
                "Read %d bytes from I2C device %02Xh\n",
                rsp.data_len,
                @as(c_uint, i2caddr),
            );
        }

        if (rsp.data_len < @as(c_int, rsize)) return -1;

        // Print the raw response buffer.
        i = 0;
        while (i < rsp.data_len) : (i += 1) {
            if (@rem(i, 16) == 0 and i != 0) _ = c.printf("\n");
            _ = c.printf(" %2.2x", @as(c_uint, rsp.data[@intCast(i)]));
        }
        _ = c.printf("\n");

        if (rsp.data_len <= 4) {
            i = 0;
            while (i < rsp.data_len) : (i += 1) {
                var bit: u32 = 0x80;
                while (bit > 0) : (bit /= 2) {
                    const set = (@as(u32, rsp.data[@intCast(i)]) & bit) != 0;
                    _ = c.printf("%s", @as([*:0]const u8, if (set) "1" else "0"));
                }
                _ = c.printf(" ");
            }
            _ = c.printf("\n");
        }
    }

    return 0;
}

/// `ipmi_raw_help()` - print the `raw` help text.
fn rawHelp() callconv(.c) void {
    c.lprintf(log.Level.notice, "RAW Commands:  raw <netfn> <cmd> [data]");
    c.print_valstr(c.ipmi_netfn_vals, "Network Function Codes", log.Level.notice);
    c.lprintf(log.Level.notice, "(can also use raw hex values)");
}

/// `ipmi_raw_main()` - the `raw` command.
fn rawMain(intf: *Intf, argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    var req: Request = undefined;
    var netfn: u8 = 0;
    var cmd: u8 = 0;
    var netfn_tmp: u16 = 0;
    var data: [256]u8 = undefined;

    if (argc == 1 and std.mem.eql(u8, std.mem.span(argv[0]), "help")) {
        rawHelp();
        return 0;
    } else if (argc < 2) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        rawHelp();
        return -1;
    } else if (@as(usize, @intCast(argc)) > data.len) {
        c.lprintf(log.Level.notice, "Raw command input limit (256 bytes) exceeded");
        return -1;
    }

    const lun: u8 = intf.target_lun;
    netfn_tmp = @truncate(c.str2val32(argv[0], c.ipmi_netfn_vals));
    if (netfn_tmp == 0xff) {
        if (isValidParam(argv[0], &netfn, "netfn") != 0) return -1;
    } else {
        if (netfn_tmp >= std.math.maxInt(u8)) {
            c.lprintf(log.Level.err, "Given netfn \"%s\" is out of range.", argv[0]);
            return -1;
        }
        netfn = @truncate(netfn_tmp);
    }

    if (isValidParam(argv[1], &cmd, "command") != 0) return -1;

    @memset(&data, 0);
    req = std.mem.zeroes(Request);
    // `netfn` is 6 bits wide and `lun` 2, so both assignments truncate.
    req.msg.netfn_lun = .{ .netfn = @truncate(netfn), .lun = @truncate(lun) };
    req.msg.cmd = cmd;
    req.msg.data = &data;

    var i: c_int = 2;
    while (i < argc) : (i += 1) {
        var val: u8 = 0;

        if (isValidParam(argv[@intCast(i)], &val, "data") != 0) return -1;

        req.msg.data.?[@intCast(i - 2)] = val;
        req.msg.data_len += 1;
    }

    c.lprintf(
        log.Level.info,
        "RAW REQ (channel=0x%x netfn=0x%x lun=0x%x cmd=0x%x data_len=%d)",
        @as(c_uint, intf.target_channel & 0x0f),
        @as(c_uint, req.msg.netfn_lun.netfn),
        @as(c_uint, req.msg.netfn_lun.lun),
        @as(c_uint, req.msg.cmd),
        @as(c_int, req.msg.data_len),
    );

    c.printbuf(req.msg.data, @as(c_int, req.msg.data_len), "RAW REQUEST");

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(
            log.Level.err,
            "Unable to send RAW command (channel=0x%x netfn=0x%x lun=0x%x cmd=0x%x)",
            @as(c_uint, intf.target_channel & 0x0f),
            @as(c_uint, req.msg.netfn_lun.netfn),
            @as(c_uint, req.msg.netfn_lun.lun),
            @as(c_uint, req.msg.cmd),
        );
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Unable to send RAW command (channel=0x%x netfn=0x%x lun=0x%x cmd=0x%x rsp=0x%x): %s",
            @as(c_uint, intf.target_channel & 0x0f),
            @as(c_uint, req.msg.netfn_lun.netfn),
            @as(c_uint, req.msg.netfn_lun.lun),
            @as(c_uint, req.msg.cmd),
            @as(c_uint, rsp.ccode),
            c.val2str(rsp.ccode, c.completion_code_vals),
        );
        return -1;
    }

    c.lprintf(log.Level.info, "RAW RSP (%d bytes)", rsp.data_len);

    // Print the raw response buffer.
    i = 0;
    while (i < rsp.data_len) : (i += 1) {
        if (@rem(i, 16) == 0 and i != 0) _ = c.printf("\n");
        _ = c.printf(" %2.2x", @as(c_uint, rsp.data[@intCast(i)]));
    }
    _ = c.printf("\n");

    return 0;
}

// ---------------------------------------------------------------------------
// C ABI surface
//
// The five symbols `lib/ipmi_raw.c` exported.  `is_valid_param()` and
// `rawi2c_usage()` were `static` there and stay private here.
// ---------------------------------------------------------------------------

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(masterWriteRead), @TypeOf(c.ipmi_master_write_read));
    abi.assertCallSignature(@TypeOf(rawspdMain), @TypeOf(c.ipmi_rawspd_main));
    abi.assertCallSignature(@TypeOf(rawi2cMain), @TypeOf(c.ipmi_rawi2c_main));
    abi.assertCallSignature(@TypeOf(rawHelp), @TypeOf(c.ipmi_raw_help));
    abi.assertCallSignature(@TypeOf(rawMain), @TypeOf(c.ipmi_raw_main));

    @export(&masterWriteRead, .{ .name = "ipmi_master_write_read", .linkage = .strong });
    @export(&rawspdMain, .{ .name = "ipmi_rawspd_main", .linkage = .strong });
    @export(&rawi2cMain, .{ .name = "ipmi_rawi2c_main", .linkage = .strong });
    @export(&rawHelp, .{ .name = "ipmi_raw_help", .linkage = .strong });
    @export(&rawMain, .{ .name = "ipmi_raw_main", .linkage = .strong });
}
