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
//! * **Formatting and parsing keep libc behavior.** The `raw` response hex
//!   dump and `i2c` response printer use checked Zig stdout writers;
//!   `printbuf` and `sscanf` still call through `ipmi_c`. Diagnostics use
//!   `util/log.zig`'s typed logger, backed by libc `snprintf` when selected
//!   and C `lprintf` otherwise. `%2.2x`, `%02Xh` and what exactly
//!   `sscanf("%u")` accepts remain observable, as do the IPMI request bytes.
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
const stdout_io = @import("../util/stdout.zig");
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
        log.print(log.Level.@"error", "ERROR: NULL pointer passed.", .{});
        return -1;
    }
    if (c.str2uchar(input_param, uchr_ptr) == 0) return 0;

    log.print(log.Level.err, "Given %s \"%s\" is invalid.", .{ label, input_param });
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
        log.print(
            log.Level.err,
            "Master Write-Read: Too many bytes (%d) to read",
            .{@as(c_int, rsize)},
        );
        return null;
    }
    if (wsize > i2c_master_max_size) {
        log.print(
            log.Level.err,
            "Master Write-Read: Too many bytes (%d) to write",
            .{@as(c_int, wsize)},
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
        log.print(
            log.Level.debug,
            "Writing %d bytes to i2cdev %02Xh",
            .{ @as(c_int, wsize), @as(c_uint, addr) },
        );
    }

    if (rsize > 0) {
        log.print(
            log.Level.debug,
            "Reading %d bytes from i2cdev %02Xh",
            .{ @as(c_int, rsize), @as(c_uint, addr) },
        );
    }

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        log.print(log.Level.err, "I2C Master Write-Read command failed", .{});
        return null;
    };
    if (rsp.ccode != 0) {
        switch (rsp.ccode) {
            0x81 => log.print(
                log.Level.err,
                "I2C Master Write-Read command failed: Lost Arbitration",
                .{},
            ),
            0x82 => log.print(
                log.Level.err,
                "I2C Master Write-Read command failed: Bus Error",
                .{},
            ),
            0x83 => log.print(
                log.Level.err,
                "I2C Master Write-Read command failed: NAK on Write",
                .{},
            ),
            0x84 => log.print(
                log.Level.err,
                "I2C Master Write-Read command failed: Truncated Read",
                .{},
            ),
            else => log.print(
                log.Level.err,
                "I2C Master Write-Read command failed: %s",
                .{c.val2str(rsp.ccode, c.completion_code_vals)},
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
    var spd_data: [raw_spd_size]u8 = undefined;
    var i: c_int = 0;

    @memset(spd_data[0..raw_spd_size], 0);

    if (argc < 2 or std.mem.eql(u8, std.mem.span(argv[0]), "help")) {
        log.print(log.Level.notice, "usage: spd <i2cbus> <i2caddr> [channel] [maxread]", .{});
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

    if (msize == 0 or msize > i2c_master_max_size) {
        log.print(
            log.Level.err,
            "SPD maxread must be between 1 and %d bytes",
            .{@as(c_int, i2c_master_max_size)},
        );
        return -1;
    }

    i2cbus = @truncate(((@as(c_uint, channel) & 0xF) << 4) |
        ((@as(c_uint, i2cbus) & 7) << 1) | 1);

    while (i < raw_spd_size) {
        const chunk: u8 = @intCast(@min(@as(c_int, msize), raw_spd_size - i));
        // C passes `(uint8_t *)&i`, i.e. the first byte of the int in memory,
        // which is the low byte of the offset on a little endian target.
        const offset: [*]u8 = @ptrCast(&i);
        const rsp = masterWriteRead(intf, i2cbus, i2caddr, offset, 1, chunk) orelse {
            log.print(log.Level.err, "Unable to perform I2C Master Write-Read", .{});
            return -1;
        };

        if (rsp.data_len < @as(c_int, chunk)) {
            log.print(
                log.Level.err,
                "SPD read at offset %d returned %d bytes, expected %d",
                .{
                    i,
                    rsp.data_len,
                    @as(c_int, chunk),
                },
            );
            return -1;
        }

        @memcpy(spd_data[@intCast(i)..][0..chunk], rsp.data[0..chunk]);
        i += @as(c_int, chunk);
    }

    _ = c.ipmi_spd_print(&spd_data, i);
    return 0;
}

/// `rawi2c_usage()`.
fn rawi2cUsage() void {
    log.print(
        log.Level.notice,
        "usage: i2c [bus=public|# [chan=#] <i2caddr> <read bytes> [write data]",
        .{},
    );
    log.print(log.Level.notice, "            bus=public is default", .{});
    log.print(
        log.Level.notice,
        "            chan=0 is default, bus= must be specified to use chan=",
        .{},
    );
    log.print(
        log.Level.notice,
        "            i2caddr is an 8-bit I2C address, only even numbers are accepted",
        .{},
    );
}

const I2cOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writeI2cResponse(
    writer: *std.Io.Writer,
    rsp: *const Response,
    wsize: u8,
    rsize: u8,
    i2caddr: u8,
    verbose: bool,
) std.Io.Writer.Error!c_int {
    if (wsize > 0) {
        if (verbose or rsize == 0)
            try stdout_io.write(writer, "Wrote {d} bytes to I2C device {X:0>2}h\n", .{ wsize, i2caddr });
    }

    if (rsize > 0) {
        if (verbose or wsize == 0)
            try stdout_io.write(writer, "Read {d} bytes from I2C device {X:0>2}h\n", .{ rsp.data_len, i2caddr });

        // The C command prints the Read line before rejecting a short reply.
        if (rsp.data_len < @as(c_int, rsize)) return -1;

        var i: c_int = 0;
        while (i < rsp.data_len) : (i += 1) {
            if (@rem(i, 16) == 0 and i != 0) try writer.writeByte('\n');
            try stdout_io.write(writer, " {x:0>2}", .{rsp.data[@intCast(i)]});
        }
        try writer.writeByte('\n');

        if (rsp.data_len <= 4) {
            i = 0;
            while (i < rsp.data_len) : (i += 1) {
                const byte = rsp.data[@intCast(i)];
                var bit: u8 = 0x80;
                while (bit != 0) : (bit >>= 1)
                    try writer.writeByte(if (byte & bit != 0) '1' else '0');
                try writer.writeByte(' ');
            }
            try writer.writeByte('\n');
        }
    }
    return 0;
}

fn emitI2cResponse(
    writer: *std.Io.Writer,
    rsp: *const Response,
    wsize: u8,
    rsize: u8,
    i2caddr: u8,
    verbose: bool,
    preflush: anytype,
) I2cOutputError!c_int {
    preflush() catch return error.CStdoutFlushFailed;
    const status = writeI2cResponse(writer, rsp, wsize, rsize, i2caddr, verbose) catch
        return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
    return status;
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
        log.print(
            log.Level.err,
            "Raw command input limit (%d bytes) exceeded",
            .{@as(c_int, i2c_master_max_size)},
        );
        return -1;
    }

    if (isValidParam(argv[@intCast(i)], &i2caddr, "i2caddr") != 0) return -1;
    i += 1;
    if (isValidParam(argv[@intCast(i)], &rsize, "read size") != 0) return -1;
    i += 1;

    if (i2caddr == 0 or (i2caddr & 1) != 0) {
        log.print(log.Level.err, "Invalid I2C address", .{});
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

    log.print(
        log.Level.info,
        "RAW I2C REQ (i2caddr=%x readbytes=%d writebytes=%d)",
        .{
            @as(c_uint, i2caddr),
            @as(c_int, rsize),
            @as(c_int, wsize),
        },
    );
    c.printbuf(&wdata, @as(c_int, wsize), "WRITE DATA");

    const rsp = masterWriteRead(intf, bus, i2caddr, &wdata, wsize, rsize) orelse {
        log.print(log.Level.err, "Unable to perform I2C Master Write-Read", .{});
        return -1;
    };

    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return emitI2cResponse(&stdout.interface, rsp, wsize, rsize, i2caddr, c.verbose != 0, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "I2C stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "I2C stdout Zig write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "I2C stdout Zig final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
}

test "raw i2c stdout matches C formatting and conditional status boundaries" {
    const Oracle = struct {
        fn append(buffer: []u8, used: *usize, comptime format: [*:0]const u8, args: anytype) !void {
            const n = @call(.auto, c.snprintf, .{
                @as([*c]u8, @ptrCast(buffer.ptr + used.*)),
                buffer.len - used.*,
                format,
            } ++ args);
            try std.testing.expect(n >= 0 and @as(usize, @intCast(n)) < buffer.len - used.*);
            used.* += @intCast(n);
        }
    };
    const cases = [_]struct {
        wsize: u8,
        rsize: u8,
        len: c_int,
        addr: u8 = 0xa0,
        verbose: bool = false,
    }{
        .{ .wsize = 0, .rsize = 0, .len = 0 },
        .{ .wsize = 0, .rsize = 0, .len = 5, .verbose = true },
        .{ .wsize = 1, .rsize = 0, .len = 0, .addr = 0x02 },
        .{ .wsize = 64, .rsize = 0, .len = 0, .addr = 0xfe, .verbose = true },
        .{ .wsize = 0, .rsize = 1, .len = 1 },
        .{ .wsize = 0, .rsize = 4, .len = 4 },
        .{ .wsize = 1, .rsize = 4, .len = 4 },
        .{ .wsize = 1, .rsize = 4, .len = 4, .verbose = true },
        .{ .wsize = 1, .rsize = 4, .len = 5 },
        .{ .wsize = 0, .rsize = 5, .len = 5 },
        .{ .wsize = 0, .rsize = 15, .len = 15 },
        .{ .wsize = 0, .rsize = 16, .len = 16 },
        .{ .wsize = 0, .rsize = 17, .len = 17 },
        .{ .wsize = 0, .rsize = 20, .len = 20 },
        .{ .wsize = 0, .rsize = 64, .len = 64 },
        .{ .wsize = 0, .rsize = 1, .len = 0 },
        .{ .wsize = 0, .rsize = 8, .len = 3 },
        .{ .wsize = 1, .rsize = 8, .len = 3 },
        .{ .wsize = 1, .rsize = 8, .len = 3, .verbose = true },
    };
    var rsp = std.mem.zeroes(Response);
    rsp.data[0] = 0x5a;
    rsp.data[1] = 0xa5;
    rsp.data[2] = 0x0f;
    rsp.data[3] = 0xf0;
    for (rsp.data[4..], 4..) |*byte, index| byte.* = @truncate(index * 41);
    var actual: [512]u8 = undefined;
    var expected: [512]u8 = undefined;

    for (cases) |case| {
        rsp.data_len = case.len;
        var writer = std.Io.Writer.fixed(&actual);
        const status = try writeI2cResponse(&writer, &rsp, case.wsize, case.rsize, case.addr, case.verbose);
        try std.testing.expectEqual(
            @as(c_int, if (case.rsize > 0 and case.len < @as(c_int, case.rsize)) -1 else 0),
            status,
        );

        var used: usize = 0;
        if (case.wsize > 0 and (case.verbose or case.rsize == 0))
            try Oracle.append(&expected, &used, "Wrote %d bytes to I2C device %02Xh\n", .{
                @as(c_int, case.wsize), @as(c_uint, case.addr),
            });
        if (case.rsize > 0) {
            if (case.verbose or case.wsize == 0)
                try Oracle.append(&expected, &used, "Read %d bytes from I2C device %02Xh\n", .{
                    case.len, @as(c_uint, case.addr),
                });
            if (case.len >= @as(c_int, case.rsize)) {
                for (rsp.data[0..@intCast(case.len)], 0..) |byte, index| {
                    if (index != 0 and index % 16 == 0) {
                        expected[used] = '\n';
                        used += 1;
                    }
                    try Oracle.append(&expected, &used, " %2.2x", .{@as(c_uint, byte)});
                }
                expected[used] = '\n';
                used += 1;
                if (case.len <= 4) {
                    for (rsp.data[0..@intCast(case.len)]) |byte| {
                        var bit: u32 = 0x80;
                        while (bit > 0) : (bit /= 2)
                            try Oracle.append(&expected, &used, "%s", .{
                                @as([*:0]const u8, if (@as(u32, byte) & bit != 0) "1" else "0"),
                            });
                        expected[used] = ' ';
                        used += 1;
                    }
                    expected[used] = '\n';
                    used += 1;
                }
            }
        }
        try std.testing.expectEqualSlices(u8, expected[0..used], writer.buffered());
    }

    rsp.data_len = 4;
    var writer = std.Io.Writer.fixed(&actual);
    try std.testing.expectEqual(@as(c_int, 0), try writeI2cResponse(&writer, &rsp, 0, 4, 0xa0, false));
    try std.testing.expectEqualStrings(
        "Read 4 bytes from I2C device A0h\n 5a a5 0f f0\n01011010 10100101 00001111 11110000 \n",
        writer.buffered(),
    );
}

test "raw i2c stdout detects preflush early late and final flush failures" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var rsp = std.mem.zeroes(Response);
    rsp.data_len = 4;
    rsp.data[0] = 0x5a;
    rsp.data[1] = 0xa5;
    rsp.data[2] = 0x0f;
    rsp.data[3] = 0xf0;
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitI2cResponse(&writer, &rsp, 1, 4, 0xa0, true, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitI2cResponse(&early, &rsp, 1, 4, 0xa0, true, Stub.preflushOk));

    const wrote = "Wrote 1 bytes to I2C device A0h\n";
    var short: [wrote.len]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitI2cResponse(&late, &rsp, 1, 4, 0xa0, true, Stub.preflushOk));
    try std.testing.expectEqualStrings(wrote, late.buffered());

    const read_hex = "Read 4 bytes from I2C device A0h\n 5a a5 0f f0\n";
    var bits_short: [read_hex.len + 3]u8 = undefined;
    var bits_late = std.Io.Writer.fixed(&bits_short);
    try std.testing.expectError(error.StdoutWriteFailed, emitI2cResponse(&bits_late, &rsp, 0, 4, 0xa0, false, Stub.preflushOk));
    try std.testing.expectEqualStrings(read_hex ++ "010", bits_late.buffered());

    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitI2cResponse(&writer, &rsp, 0, 4, 0xa0, false, Stub.preflushOk));
    try std.testing.expectEqualStrings(read_hex ++ "01011010 10100101 00001111 11110000 \n", writer.buffered());

    rsp.data_len = 3;
    var short_reply = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, -1), try emitI2cResponse(&short_reply, &rsp, 1, 8, 0xa0, true, Stub.preflushOk));
    try std.testing.expectEqualStrings(wrote ++ "Read 3 bytes from I2C device A0h\n", short_reply.buffered());
    var short_reply_fail = std.Io.Writer.fixed(&storage);
    short_reply_fail.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitI2cResponse(&short_reply_fail, &rsp, 1, 8, 0xa0, true, Stub.preflushOk));
    try std.testing.expectEqualStrings(wrote ++ "Read 3 bytes from I2C device A0h\n", short_reply_fail.buffered());
}

test "raw i2c stdout preserves buffered C and Zig output order" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    var rsp = std.mem.zeroes(Response);
    rsp.data_len = 1;
    rsp.data[0] = 0xff;
    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try std.testing.expectEqual(@as(c_int, 0), try emitI2cResponse(&stdout.interface, &rsp, 1, 1, 0xa0, true, stdout_io.trySyncC));
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));

    var captured: [256]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings(
        "before|Wrote 1 bytes to I2C device A0h\nRead 1 bytes from I2C device A0h\n ff\n11111111 \n|after\n",
        captured[0..@intCast(length)],
    );
}

/// `ipmi_raw_help()` - print the `raw` help text.
fn rawHelp() callconv(.c) void {
    log.print(log.Level.notice, "RAW Commands:  raw <netfn> <cmd> [data]", .{});
    c.print_valstr(c.ipmi_netfn_vals, "Network Function Codes", log.Level.notice);
    log.print(log.Level.notice, "(can also use raw hex values)", .{});
}

fn writeRawResponse(writer: *std.Io.Writer, rsp: *const Response) std.Io.Writer.Error!void {
    var i: c_int = 0;
    while (i < rsp.data_len) : (i += 1) {
        if (@rem(i, 16) == 0 and i != 0) try writer.writeByte('\n');
        try stdout_io.write(writer, " {x:0>2}", .{rsp.data[@intCast(i)]});
    }
    try writer.writeByte('\n');
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
        log.print(log.Level.err, "Not enough parameters given.", .{});
        rawHelp();
        return -1;
    } else if (@as(usize, @intCast(argc)) > data.len) {
        log.print(log.Level.notice, "Raw command input limit (256 bytes) exceeded", .{});
        return -1;
    }

    const lun: u8 = intf.target_lun;
    netfn_tmp = @truncate(c.str2val32(argv[0], c.ipmi_netfn_vals));
    if (netfn_tmp == 0xff) {
        if (isValidParam(argv[0], &netfn, "netfn") != 0) return -1;
    } else {
        if (netfn_tmp >= std.math.maxInt(u8)) {
            log.print(log.Level.err, "Given netfn \"%s\" is out of range.", .{argv[0]});
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

    log.print(
        log.Level.info,
        "RAW REQ (channel=0x%x netfn=0x%x lun=0x%x cmd=0x%x data_len=%d)",
        .{
            @as(c_uint, intf.target_channel & 0x0f),
            @as(c_uint, req.msg.netfn_lun.netfn),
            @as(c_uint, req.msg.netfn_lun.lun),
            @as(c_uint, req.msg.cmd),
            @as(c_int, req.msg.data_len),
        },
    );

    c.printbuf(req.msg.data, @as(c_int, req.msg.data_len), "RAW REQUEST");

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        log.print(
            log.Level.err,
            "Unable to send RAW command (channel=0x%x netfn=0x%x lun=0x%x cmd=0x%x)",
            .{
                @as(c_uint, intf.target_channel & 0x0f),
                @as(c_uint, req.msg.netfn_lun.netfn),
                @as(c_uint, req.msg.netfn_lun.lun),
                @as(c_uint, req.msg.cmd),
            },
        );
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(
            log.Level.err,
            "Unable to send RAW command (channel=0x%x netfn=0x%x lun=0x%x cmd=0x%x rsp=0x%x): %s",
            .{
                @as(c_uint, intf.target_channel & 0x0f),
                @as(c_uint, req.msg.netfn_lun.netfn),
                @as(c_uint, req.msg.netfn_lun.lun),
                @as(c_uint, req.msg.cmd),
                @as(c_uint, rsp.ccode),
                c.val2str(rsp.ccode, c.completion_code_vals),
            },
        );
        return -1;
    }

    log.print(log.Level.info, "RAW RSP (%d bytes)", .{rsp.data_len});

    stdout_io.trySyncC() catch {
        log.print(log.Level.err, "RAW stdout C preflush failed (errno %d)", .{std.c._errno().*});
        return -1;
    };
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    writeRawResponse(&stdout.interface, rsp) catch |err| {
        log.print(log.Level.err, "RAW stdout Zig write failed: %s", .{@errorName(stdout.err orelse err).ptr});
        return -1;
    };
    stdout.interface.flush() catch |err| {
        log.print(log.Level.err, "RAW stdout Zig final flush failed: %s", .{@errorName(stdout.err orelse err).ptr});
        return -1;
    };

    return 0;
}

test "raw stdout matches libc byte formatting across wraps" {
    var rsp = std.mem.zeroes(Response);
    for (&rsp.data, 0..) |*byte, index| byte.* = @truncate(index);
    var actual: [4 * ipmi.buf_size]u8 = undefined;
    var expected: [4 * ipmi.buf_size]u8 = undefined;

    for ([_]c_int{ 0, 1, 15, 16, 17, 31, 32, 33, 256, ipmi.buf_size }) |len| {
        rsp.data_len = len;
        var writer = std.Io.Writer.fixed(&actual);
        try writeRawResponse(&writer, &rsp);

        var used: usize = 0;
        for (rsp.data[0..@intCast(len)], 0..) |byte, index| {
            if (index != 0 and index % 16 == 0) {
                expected[used] = '\n';
                used += 1;
            }
            const printed = c.snprintf(@ptrCast(&expected[used]), expected.len - used, " %2.2x", @as(c_uint, byte));
            try std.testing.expectEqual(@as(c_int, 3), printed);
            used += @intCast(printed);
        }
        expected[used] = '\n';
        used += 1;
        try std.testing.expectEqualSlices(u8, expected[0..used], writer.buffered());
    }

    rsp.data_len = 1;
    rsp.data[0] = 0xff;
    var writer = std.Io.Writer.fixed(&actual);
    try writeRawResponse(&writer, &rsp);
    try std.testing.expectEqualStrings(" ff\n", writer.buffered());
}

test "raw stdout propagates first and later writer failures" {
    var rsp = std.mem.zeroes(Response);
    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeRawResponse(&failing, &rsp));

    rsp.data_len = 17;
    try std.testing.expectError(error.WriteFailed, writeRawResponse(&failing, &rsp));

    var first: [3]u8 = undefined;
    var first_writer = std.Io.Writer.fixed(&first);
    try std.testing.expectError(error.WriteFailed, writeRawResponse(&first_writer, &rsp));
    try std.testing.expectEqualStrings(" 00", first_writer.buffered());

    var wrapped: [49]u8 = undefined;
    var wrapped_writer = std.Io.Writer.fixed(&wrapped);
    try std.testing.expectError(error.WriteFailed, writeRawResponse(&wrapped_writer, &rsp));
    try std.testing.expectEqual(@as(u8, '\n'), wrapped_writer.buffered()[48]);
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
