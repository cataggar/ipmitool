//! Non-interactive shell commands, swapped with src/ipmishell.c by ipmishell.
const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");
const stdout_io = @import("../util/stdout.zig");
const frontend_log = @import("logging.zig");
const shell = @import("ipmishell.zig");

const allocator = std.heap.c_allocator;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Output = union(enum) {
    echo: struct { argc: c_int, argv: [*c][*c]u8 },
    hostname: []const u8,
    username: []const u8,
    password,
    authtype: []const u8,
    privlvl: []const u8,
    port: c_int,
    localaddr: u32,
    targetaddr: u32,
};

fn writeOutput(writer: *std.Io.Writer, output: Output) std.Io.Writer.Error!void {
    switch (output) {
        .echo => |args| {
            for (0..@intCast(@max(args.argc, 0))) |i| {
                try writer.print("{s} ", .{std.mem.span(args.argv[i])});
            }
            try writer.writeByte('\n');
        },
        .hostname => |name| try writer.print("Set session hostname to {s}\n", .{name}),
        .username => |name| try writer.print("Set session username to {s}\n", .{name}),
        .password => try writer.writeAll("Set session password\n"),
        .authtype => |name| try writer.print("Set session authtype to {s}\n", .{name}),
        .privlvl => |name| try writer.print("Set session privilege level to {s}\n", .{name}),
        .port => |port| try writer.print("Set session port to {d}\n", .{port}),
        .localaddr => |addr| try writer.print("Set local IPMB address to 0x{x:0>2}\n", .{addr}),
        .targetaddr => |addr| try writer.print("Set remote IPMB address to 0x{x:0>2}\n", .{addr}),
    }
}

fn emitOutput(output: Output) (error{CStdoutFlushFailed} || std.Io.Writer.Error)!void {
    try stdout_io.trySyncC();
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try writeOutput(&stdout.interface, output);
    try stdout.interface.flush();
}

fn stdoutResult(command: [*:0]const u8, output: Output) c_int {
    emitOutput(output) catch |err| {
        frontend_log.print(log.Level.err, "%s: stdout %s", .{ command, @errorName(err).ptr });
        return -1;
    };
    return 0;
}

fn echoMain(_: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return stdoutResult("echo", .{ .echo = .{ .argc = argc, .argv = argv } });
}

fn setUsage() void {
    frontend_log.print(log.Level.notice, "Usage: set <option> <value>\n", .{});
    frontend_log.print(log.Level.notice, "Options are:", .{});
    frontend_log.print(log.Level.notice, "    hostname <host>        Session hostname", .{});
    frontend_log.print(log.Level.notice, "    username <user>        Session username", .{});
    frontend_log.print(log.Level.notice, "    password <pass>        Session password", .{});
    frontend_log.print(log.Level.notice, "    privlvl <level>        Session privilege level force", .{});
    frontend_log.print(log.Level.notice, "    authtype <type>        Authentication type force", .{});
    frontend_log.print(log.Level.notice, "    localaddr <addr>       Local IPMB address", .{});
    frontend_log.print(log.Level.notice, "    targetaddr <addr>      Remote target IPMB address", .{});
    frontend_log.print(log.Level.notice, "    port <port>            Remote RMCP port", .{});
    frontend_log.print(log.Level.notice, "    csv [level]            enable output in comma separated format", .{});
    frontend_log.print(log.Level.notice, "    verbose [level]        Verbose level", .{});
    frontend_log.print(log.Level.notice, "", .{});
}

fn setMain(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    if (argc <= 0 or eq(std.mem.span(argv[0]), "help")) {
        setUsage();
        return -1;
    }
    const name = std.mem.span(argv[0]);
    if (eq(name, "verbose") or eq(name, "csv")) {
        const value = if (eq(name, "verbose")) &c.verbose else &c.csv_output;
        if (argc > 1) {
            if (c.str2int(argv[1], value) != 0) {
                frontend_log.print(log.Level.err, "Given %s '%s' argument is invalid.", .{ argv[0], argv[1] });
                return -1;
            }
        } else if (eq(name, "verbose")) {
            value.* +%= 1;
        } else value.* = 1;
        return 0;
    }
    if (argc == 1) {
        setUsage();
        return -1;
    }
    const value = argv[1];
    var response: Output = undefined;
    if (eq(name, "host") or eq(name, "hostname")) {
        c.ipmi_intf_session_set_hostname(@ptrCast(intf), value);
        if (intf.session == null) {
            frontend_log.print(log.Level.err, "Failed to set session hostname.", .{});
            return -1;
        }
        response = .{ .hostname = if (intf.ssn_params.hostname) |host| std.mem.span(host) else "(null)" };
    } else if (eq(name, "user") or eq(name, "username")) {
        c.ipmi_intf_session_set_username(@ptrCast(intf), value);
        if (intf.session == null) {
            frontend_log.print(log.Level.err, "Failed to set session username.", .{});
            return -1;
        }
        response = .{ .username = std.mem.sliceTo(&intf.ssn_params.username, 0) };
    } else if (eq(name, "pass") or eq(name, "password")) {
        c.ipmi_intf_session_set_password(@ptrCast(intf), value);
        if (intf.session == null) {
            frontend_log.print(log.Level.err, "Failed to set session password.", .{});
            return -1;
        }
        response = .password;
    } else if (eq(name, "authtype") or eq(name, "privlvl")) {
        const table = if (eq(name, "authtype")) c.ipmi_authtype_session_vals else c.ipmi_privlvl_vals;
        const parsed = c.str2val(value, table);
        if (parsed == 0xff) {
            frontend_log.print(log.Level.err, if (eq(name, "authtype")) "Invalid authtype: %s" else "Invalid privilege level: %s", .{value});
            return -1;
        }
        if (eq(name, "authtype")) {
            c.ipmi_intf_session_set_authtype(@ptrCast(intf), @intCast(parsed));
        } else c.ipmi_intf_session_set_privlvl(@ptrCast(intf), @intCast(parsed));
        if (intf.session == null) {
            frontend_log.print(log.Level.err, if (eq(name, "authtype")) "Failed to set session authtype." else "Failed to set session privilege level.", .{});
            return -1;
        }
        if (eq(name, "authtype")) {
            response = .{ .authtype = std.mem.span(c.val2str(intf.ssn_params.authtype_set, table)) };
        } else response = .{ .privlvl = std.mem.span(c.val2str(intf.ssn_params.privlvl, table)) };
    } else if (eq(name, "port")) {
        var port: c_int = 0;
        if (c.str2int(value, &port) != 0 or port > 65535) {
            frontend_log.print(log.Level.err, "Given port '%s' is invalid.", .{value});
            return -1;
        }
        c.ipmi_intf_session_set_port(@ptrCast(intf), port);
        if (intf.session == null) {
            frontend_log.print(log.Level.err, "Failed to set session port.", .{});
            return -1;
        }
        response = .{ .port = intf.ssn_params.port };
    } else if (eq(name, "localaddr") or eq(name, "targetaddr")) {
        var addr: u8 = 0;
        if (c.str2uchar(value, &addr) != 0) {
            frontend_log.print(log.Level.err, "Given %s '%s' is invalid.", .{ argv[0], value });
            return -1;
        }
        if (eq(name, "localaddr")) {
            intf.my_addr = addr;
            response = .{ .localaddr = intf.my_addr };
        } else {
            intf.target_addr = addr;
            response = .{ .targetaddr = intf.target_addr };
        }
    } else {
        setUsage();
        return -1;
    }
    return stdoutResult("set", response);
}

const ExecLine = union(enum) {
    command: []const u8,
    overflow,
};

fn readExecLine(fp: *c.FILE, buf: *[2047]u8) ?ExecLine {
    var count: usize = 0;
    while (count < buf.len) {
        const ch = c.fgetc(fp);
        if (ch == c.EOF) {
            if (c.ferror(fp) != 0) return null;
            break;
        }
        buf[count] = @intCast(ch);
        count += 1;
        if (ch == '\n') break;
    }
    if (count == 0) return null;

    const visible = std.mem.indexOfScalar(u8, buf[0..count], 0) orelse count;
    if (visible == buf.len and buf[count - 1] != '\n') {
        var ch = c.fgetc(fp);
        if (ch != c.EOF and ch != '\n') {
            while (true) {
                ch = c.fgetc(fp);
                if (ch == c.EOF or ch == '\n') break;
            }
            return .overflow;
        }
    }
    return .{ .command = buf[0..visible] };
}

fn execMain(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    if (argc < 1) {
        frontend_log.print(log.Level.err, "Usage: exec <filename>", .{});
        return -1;
    }
    const fp = c.ipmi_open_file(argv[0], 0) orelse return -1;
    defer _ = c.fclose(fp);
    var buf: [2047]u8 = undefined;
    var rc: c_int = 0;
    while (readExecLine(fp, &buf)) |line| {
        const contents = switch (line) {
            .overflow => {
                frontend_log.print(log.Level.err, "exec: command line exceeds 2047 bytes", .{});
                rc = -1;
                continue;
            },
            .command => |bytes| bytes,
        };
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const parsed = shell.parse(arena_state.allocator(), contents, true) catch |err| {
            frontend_log.print(log.Level.err, "Invalid command line: %s", .{@errorName(err).ptr});
            rc = -1;
            continue;
        };
        if (parsed.items.len == 0) continue;
        var args: [shell.max_args + 1][*c]u8 = @splat(null);
        for (parsed.items, 0..) |arg, i| args[i] = arg;
        const result = c.ipmi_cmd_run(@ptrCast(intf), args[0], @intCast(parsed.items.len - 1), &args[1]);
        if (result != 0) rc = result;
    }
    if (c.ferror(fp) != 0) {
        frontend_log.print(log.Level.err, "exec: unable to read file", .{});
        return -1;
    }
    return rc;
}

fn fgetsExecLine(fp: *c.FILE, buf: *[2048]u8) ?ExecLine {
    if (c.fgets(buf, buf.len, fp) == null) return null;
    const len = c.strlen(buf);
    if (len == buf.len - 1 and buf[len - 1] != '\n') {
        var ch = c.fgetc(fp);
        if (ch != c.EOF and ch != '\n') {
            while (true) {
                ch = c.fgetc(fp);
                if (ch == c.EOF or ch == '\n') break;
            }
            return .overflow;
        }
    }
    return .{ .command = buf[0..len] };
}

fn expectExecLineParity(bytes: []const u8) !void {
    const mem_oracle = try std.testing.allocator.alloc(u8, @max(bytes.len, 1));
    defer std.testing.allocator.free(mem_oracle);
    const mem_scanned = try std.testing.allocator.alloc(u8, @max(bytes.len, 1));
    defer std.testing.allocator.free(mem_scanned);
    @memcpy(mem_oracle[0..bytes.len], bytes);
    @memcpy(mem_scanned[0..bytes.len], bytes);

    const oracle = c.fmemopen(mem_oracle.ptr, bytes.len, "r") orelse return error.MemoryStreamFailed;
    defer _ = c.fclose(oracle);
    const scanned = c.fmemopen(mem_scanned.ptr, bytes.len, "r") orelse return error.MemoryStreamFailed;
    defer _ = c.fclose(scanned);

    var c_buf: [2048]u8 = undefined;
    var zig_buf: [2047]u8 = undefined;
    var lines: usize = 0;
    while (true) {
        const expected = fgetsExecLine(oracle, &c_buf);
        const actual = readExecLine(scanned, &zig_buf);
        try std.testing.expectEqual(c.ftell(oracle), c.ftell(scanned));
        try std.testing.expectEqual(c.feof(oracle) != 0, c.feof(scanned) != 0);
        try std.testing.expectEqual(c.ferror(oracle) != 0, c.ferror(scanned) != 0);
        if (expected) |line| {
            const found = actual orelse return error.MissingExecLine;
            switch (line) {
                .overflow => try std.testing.expect(found == .overflow),
                .command => |text| switch (found) {
                    .overflow => return error.UnexpectedExecOverflow,
                    .command => |other| try std.testing.expectEqualSlices(u8, text, other),
                },
            }
        } else {
            try std.testing.expect(actual == null);
            break;
        }
        lines += 1;
        try std.testing.expect(lines <= bytes.len + 1);
    }
}

test "exec line scanner matches fgets fgetc strlen framing and offsets" {
    try expectExecLineParity("");
    try expectExecLineParity("\n\r\n\recho first\r\necho partial");
    for (0..256) |byte| {
        const input = [_]u8{ @intCast(byte), '\r', '\n', 'e', 'c', 'h', 'o', '\n' };
        try expectExecLineParity(&input);
    }

    var input: [8192]u8 = undefined;
    for ([_]usize{ 0, 1, 2046, 2047, 2048, 4096 }) |size| {
        @memset(input[0..size], 'x');
        try expectExecLineParity(input[0..size]);
        input[size] = '\n';
        @memcpy(input[size + 1 .. size + 12], "echo after\n");
        try expectExecLineParity(input[0 .. size + 12]);
        if (size >= 2047) {
            for ([_]usize{ 0, 2046, 2047 }) |nul| {
                input[nul] = 0;
                try expectExecLineParity(input[0 .. size + 12]);
                input[nul] = 'x';
            }
        }
    }
    try expectExecLineParity("echo before\x00ignored\r\necho after\n");
}

test "exec line scanner preserves FILE read errors" {
    const oracle = c.fopen("/dev/null", "w") orelse return error.FileOpenFailed;
    defer _ = c.fclose(oracle);
    const scanned = c.fopen("/dev/null", "w") orelse return error.FileOpenFailed;
    defer _ = c.fclose(scanned);
    var c_buf: [2048]u8 = undefined;
    var zig_buf: [2047]u8 = undefined;
    try std.testing.expect(fgetsExecLine(oracle, &c_buf) == null);
    try std.testing.expect(readExecLine(scanned, &zig_buf) == null);
    try std.testing.expect(c.ferror(oracle) != 0);
    try std.testing.expect(c.ferror(scanned) != 0);
    try std.testing.expectEqual(c.feof(oracle) != 0, c.feof(scanned) != 0);
}

const FaultingExecCookie = struct {
    input: []const u8,
    fail_after: usize,
    offset: usize = 0,
    failures: usize = 0,
};

fn faultingExecRead(cookie: ?*anyopaque, dest: [*c]u8, capacity: usize) callconv(.c) c_long {
    const state: *FaultingExecCookie = @ptrCast(@alignCast(cookie.?));
    if (state.offset == state.fail_after) {
        state.failures += 1;
        std.c._errno().* = c.EIO;
        return -1;
    }
    const count = @min(capacity, state.fail_after - state.offset);
    @memcpy(dest[0..count], state.input[state.offset..][0..count]);
    state.offset += count;
    return @intCast(count);
}

fn expectExecReadErrorParity(input: []const u8, fail_after: usize, complete_lines: usize) !void {
    var c_state: FaultingExecCookie = .{ .input = input, .fail_after = fail_after };
    var zig_state: FaultingExecCookie = .{ .input = input, .fail_after = fail_after };
    const funcs: c.cookie_io_functions_t = .{ .read = &faultingExecRead };
    const oracle = c.fopencookie(&c_state, "r", funcs) orelse return error.CookieOpenFailed;
    defer _ = c.fclose(oracle);
    const scanned = c.fopencookie(&zig_state, "r", funcs) orelse return error.CookieOpenFailed;
    defer _ = c.fclose(scanned);

    var c_buf: [2048]u8 = undefined;
    var zig_buf: [2047]u8 = undefined;
    for (0..complete_lines) |_| {
        const expected = fgetsExecLine(oracle, &c_buf) orelse return error.MissingOracleLine;
        const actual = readExecLine(scanned, &zig_buf) orelse return error.MissingExecLine;
        switch (expected) {
            .overflow => try std.testing.expect(actual == .overflow),
            .command => |line| switch (actual) {
                .overflow => return error.UnexpectedExecOverflow,
                .command => |other| try std.testing.expectEqualSlices(u8, line, other),
            },
        }
    }
    try std.testing.expect(fgetsExecLine(oracle, &c_buf) == null);
    try std.testing.expect(readExecLine(scanned, &zig_buf) == null);
    try std.testing.expect(c.ferror(oracle) != 0);
    try std.testing.expect(c.ferror(scanned) != 0);
    try std.testing.expectEqual(c_state.offset, zig_state.offset);
    try std.testing.expectEqual(fail_after, zig_state.offset);
    try std.testing.expect(c_state.failures > 0 and zig_state.failures > 0);
}

test "exec line scanner discards a partial command on a mid-line FILE read error" {
    try expectExecReadErrorParity("echo partial\n", "echo pa".len, 0);
    try expectExecReadErrorParity("echo good\necho partial\n", "echo good\necho pa".len, 1);
    try expectExecReadErrorParity("echo \x00ignored\n", "echo \x00ign".len, 0);
}

test "exec line scanner preserves a complete chunk on failed lookahead or discard" {
    const full = [_]u8{'x'} ** 2047;
    try expectExecReadErrorParity(&full, full.len, 1);
    const overlong = [_]u8{'x'} ** 2048;
    try expectExecReadErrorParity(&overlong, overlong.len, 1);
}

fn expectOutputMatchesLibc(output: Output, comptime format: [*:0]const u8, args: anytype) !void {
    var actual: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&actual);
    try writeOutput(&writer, output);

    var expected: [1024]u8 = undefined;
    const len = @call(.auto, c.snprintf, .{ &expected, expected.len, format } ++ args);
    try std.testing.expect(len >= 0 and len < expected.len);
    try std.testing.expectEqualSlices(u8, expected[0..@intCast(len)], writer.buffered());
}

test "shell stdout echo retains C string bytes, spaces and newline" {
    var args = [_][*c]u8{ @constCast("two words"), @constCast(""), @constCast("café"), @constCast("x" ** 260) };
    const argv: [*c][*c]u8 = @ptrCast(&args);
    var actual: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&actual);
    try writeOutput(&writer, .{ .echo = .{ .argc = args.len, .argv = argv } });

    var expected: [512]u8 = undefined;
    const len = c.snprintf(&expected, expected.len, "%s %s %s %s \n", args[0], args[1], args[2], args[3]);
    try std.testing.expect(len >= 0 and len < expected.len);
    try std.testing.expectEqualSlices(u8, expected[0..@intCast(len)], writer.buffered());

    writer = std.Io.Writer.fixed(&actual);
    try writeOutput(&writer, .{ .echo = .{ .argc = 0, .argv = null } });
    try std.testing.expectEqualStrings("\n", writer.buffered());
    writer = std.Io.Writer.fixed(&actual);
    try writeOutput(&writer, .{ .echo = .{ .argc = -1, .argv = null } });
    try std.testing.expectEqualStrings("\n", writer.buffered());
}

test "shell stdout set responses match C strings, signed port and two-digit hex" {
    try expectOutputMatchesLibc(.{ .hostname = "server.example" }, "Set session hostname to %s\n", .{@as([*:0]const u8, "server.example")});
    var stored_username = [_]u8{'a'} ** 17;
    stored_username[16] = 0;
    try expectOutputMatchesLibc(
        .{ .username = std.mem.sliceTo(&stored_username, 0) },
        "Set session username to %s\n",
        .{@as([*c]const u8, @ptrCast(&stored_username))},
    );
    try expectOutputMatchesLibc(.password, "Set session password\n", .{});
    try expectOutputMatchesLibc(.{ .authtype = "MD5" }, "Set session authtype to %s\n", .{@as([*:0]const u8, "MD5")});
    try expectOutputMatchesLibc(.{ .privlvl = "ADMINISTRATOR" }, "Set session privilege level to %s\n", .{@as([*:0]const u8, "ADMINISTRATOR")});
    for ([_]c_int{ -1, 0, 623, 65535 }) |port|
        try expectOutputMatchesLibc(.{ .port = port }, "Set session port to %d\n", .{port});
    for ([_]u32{ 0, 1, 15, 16, 255, 256, 0xffff_ffff }) |addr| {
        try expectOutputMatchesLibc(.{ .localaddr = addr }, "Set local IPMB address to 0x%02x\n", .{@as(c_uint, addr)});
        try expectOutputMatchesLibc(.{ .targetaddr = addr }, "Set remote IPMB address to 0x%02x\n", .{@as(c_uint, addr)});
    }
}

test "shell stdout does not report success on early or late writer failure" {
    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeOutput(&failing, .{ .echo = .{ .argc = 0, .argv = null } }));
    const cases = [_]Output{
        .{ .hostname = "host" }, .{ .username = "user" },         .password,
        .{ .authtype = "MD5" },  .{ .privlvl = "ADMINISTRATOR" }, .{ .port = 623 },
        .{ .localaddr = 0 },     .{ .targetaddr = 255 },
    };
    for (cases) |output| {
        try std.testing.expectError(error.WriteFailed, writeOutput(&failing, output));
        var rendered: [128]u8 = undefined;
        var complete = std.Io.Writer.fixed(&rendered);
        try writeOutput(&complete, output);
        var short: [128]u8 = undefined;
        var late = std.Io.Writer.fixed(short[0 .. complete.buffered().len - 1]);
        try std.testing.expectError(error.WriteFailed, writeOutput(&late, output));
        try std.testing.expectEqualSlices(u8, complete.buffered()[0 .. complete.buffered().len - 1], late.buffered());
    }
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(execMain), @TypeOf(c.ipmi_exec_main));
    abi.assertCallSignature(@TypeOf(setMain), @TypeOf(c.ipmi_set_main));
    abi.assertCallSignature(@TypeOf(echoMain), @TypeOf(c.ipmi_echo_main));
    @export(&execMain, .{ .name = "ipmi_exec_main" });
    @export(&setMain, .{ .name = "ipmi_set_main" });
    @export(&echoMain, .{ .name = "ipmi_echo_main" });
}
