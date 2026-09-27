//! Port of `lib/ipmi_user.c`: the `user` command plus the four Get/Set User
//! Access, Get User Name and Set User Password primitives that the rest of
//! ipmitool calls into.
//!
//! Selected with `zig build -Dzig-modules=user`, which drops `lib/ipmi_user.c`
//! from the compile and links this module instead.
//!
//! Fourteen symbols have external linkage.  Four of them are called from other
//! translation units - `_ipmi_set_user_password()` and `_ipmi_set_user_access()`
//! from `lib/ipmi_lanp.c`, `_ipmi_get_user_access()`, `_ipmi_get_user_name()`
//! and `_ipmi_set_user_access()` from `lib/ipmi_channel.c` - so all fourteen
//! keep their C names and signatures.
//!
//! Things worth knowing before reading on:
//!
//! * **Only five of the fourteen have a prototype.**
//!   `include/ipmitool/ipmi_user.h` declares `ipmi_user_main()` and the four
//!   `_ipmi_*` primitives.  `ask_password()`,
//!   `ipmi_user_build_password_prompt()` and the seven `ipmi_user_*`
//!   subcommand handlers are bare globals declared nowhere, so there is no C
//!   declaration for `assertCallSignature` to compare against; their
//!   signatures are transcribed from the definitions in the `.c`.
//! `ask_password()` returns a pointer into `getpass()`'s static buffer.
//! The first prompted password must be saved before asking for confirmation;
//! the bounded copy and request buffer are wiped after use. See issue #39.
//!
//! Everything this module still needs from C - `printf`, `val2str`,
//! `eval_ccode`, `getpass`, `str2int`, `str2uchar` and the `is_ipmi_*`
//! validators - is reached through the `ipmi_c` bridge. Diagnostics use the
//! shared typed logger, which falls back to C `lprintf` when Zig logging is
//! not selected. The list, summary and password-test results use checked Zig stdout.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const stdout_io = @import("../util/stdout.zig");
const ipmi = @import("../core/ipmi.zig");
const intf_mod = @import("../intf/intf.zig");

const Intf = intf_mod.Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;

const UserAccess = c.struct_user_access_t;
const UserName = c.struct_user_name_t;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const netfn_app: u6 = @intCast(c.IPMI_NETFN_APP);

const cmd_set_user_access: u8 = @intCast(c.IPMI_SET_USER_ACCESS);
const cmd_get_user_access: u8 = @intCast(c.IPMI_GET_USER_ACCESS);
const cmd_set_user_name: u8 = @intCast(c.IPMI_SET_USER_NAME);
const cmd_get_user_name: u8 = @intCast(c.IPMI_GET_USER_NAME);
const cmd_set_user_password: u8 = @intCast(c.IPMI_SET_USER_PASSWORD);

const password_disable_user: u8 = @intCast(c.IPMI_PASSWORD_DISABLE_USER);
const password_enable_user: u8 = @intCast(c.IPMI_PASSWORD_ENABLE_USER);
const password_set_password: u8 = @intCast(c.IPMI_PASSWORD_SET_PASSWORD);
const password_test_password: u8 = @intCast(c.IPMI_PASSWORD_TEST_PASSWORD);

const uid_mask: u8 = @intCast(c.IPMI_UID_MASK);
const uid_max: u8 = @intCast(c.IPMI_UID_MAX);

/// `USER_PW_IPMI15_LEN`: IPMI 1.5 only allowed for 16 bytes.
const pw_ipmi15_len: u8 = 16;
/// `USER_PW_IPMI20_LEN`: IPMI 2.0 allows for 20 bytes.
const pw_ipmi20_len: u8 = 20;
/// `USER_PW_MAX_LEN`.
const pw_max_len: u8 = pw_ipmi20_len;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn cIntf(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}

fn eql(a: [*:0]const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), b);
}

/// `IPMI_UID()`: the user id is a six bit field.
fn ipmiUid(id: u8) u8 {
    return id & uid_mask;
}

/// One `intf->sendrecv()` round trip.
fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    const send = intf.sendrecv orelse return null;
    return send(intf, req);
}

fn wipePassword(buf: []u8) void {
    for (buf) |*byte| {
        @as(*volatile u8, @ptrCast(byte)).* = 0;
    }
}

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

/// `_ipmi_get_user_access()`: Get User Access for the channel and user id
/// already set in `user_access_rsp`.
///
/// Returns a negative number on error and the completion code otherwise.
fn getUserAccess(intf: *Intf, user_access_rsp: ?*UserAccess) callconv(.c) c_int {
    var req = std.mem.zeroes(Request);
    var data: [2]u8 = undefined;
    const ua = user_access_rsp orelse return -3;

    data[0] = ua.channel & 0x0f;
    data[1] = ipmiUid(ua.user_id);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = cmd_get_user_access;
    req.msg.data = &data;
    req.msg.data_len = 2;
    const rsp = sendrecv(intf, &req) orelse return -1;
    if (rsp.ccode != 0) {
        return rsp.ccode;
    } else if (rsp.data_len != 4) {
        return -2;
    }
    ua.max_user_ids = ipmiUid(rsp.data[0]);
    ua.enable_status = rsp.data[1] & 0xc0;
    ua.enabled_user_ids = ipmiUid(rsp.data[1]);
    ua.fixed_user_ids = ipmiUid(rsp.data[2]);
    ua.callin_callback = rsp.data[3] & 0x40;
    ua.link_auth = rsp.data[3] & 0x20;
    ua.ipmi_messaging = rsp.data[3] & 0x10;
    ua.privilege_limit = rsp.data[3] & 0x0f;
    return rsp.ccode;
}

/// `_ipmi_get_user_name()`: Get User Name for the user id already set in
/// `user_name_ptr`.
///
/// Returns a negative number on error and the completion code otherwise.
fn getUserName(intf: *Intf, user_name_ptr: ?*UserName) callconv(.c) c_int {
    var req = std.mem.zeroes(Request);
    var data: [1]u8 = undefined;
    const un = user_name_ptr orelse return -3;

    data[0] = ipmiUid(un.user_id);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = cmd_get_user_name;
    req.msg.data = &data;
    req.msg.data_len = 1;
    const rsp = sendrecv(intf, &req) orelse return -1;
    if (rsp.ccode != 0) {
        return rsp.ccode;
    } else if (rsp.data_len != 16) {
        return -2;
    }
    @memset(un.user_name[0..17], 0);
    @memcpy(un.user_name[0..16], rsp.data[0..16]);
    return rsp.ccode;
}

/// `_ipmi_set_user_access()`: Set User Access for the channel and user id in
/// `user_access_req`.
///
/// Returns a negative number on error and the completion code otherwise.
fn setUserAccess(
    intf: *Intf,
    user_access_req: ?*UserAccess,
    change_priv_limit_only: u8,
) callconv(.c) c_int {
    var data: [4]u8 = undefined;
    var req = std.mem.zeroes(Request);
    const ua = user_access_req orelse return -3;

    data[0] = if (change_priv_limit_only != 0) 0x00 else 0x80;
    if (ua.callin_callback != 0) {
        data[0] |= 0x40;
    }
    if (ua.link_auth != 0) {
        data[0] |= 0x20;
    }
    if (ua.ipmi_messaging != 0) {
        data[0] |= 0x10;
    }
    data[0] |= (ua.channel & 0x0f);
    data[1] = ipmiUid(ua.user_id);
    data[2] = ua.privilege_limit & 0x0f;
    data[3] = ua.session_limit & 0x0f;
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = cmd_set_user_access;
    req.msg.data = &data;
    req.msg.data_len = 4;
    const rsp = sendrecv(intf, &req) orelse return -1;
    return rsp.ccode;
}

/// `_ipmi_set_user_password()`: enable, disable, set or test a password.
///
/// The request buffer is heap allocated exactly as in C, so the `(-4)` malloc
/// failure return is reachable in the same circumstances.
///
/// Returns a negative number on error and the completion code otherwise.
fn setUserPassword(
    intf: *Intf,
    user_id: u8,
    operation: u8,
    password: ?[*:0]const u8,
    is_twenty_byte: u8,
) callconv(.c) c_int {
    var req = std.mem.zeroes(Request);
    const data_len: u8 = if (is_twenty_byte != 0) 22 else 18;
    const raw = std.c.malloc(@sizeOf(u8) * data_len) orelse return -4;
    const data: [*]u8 = @ptrCast(raw);
    defer {
        wipePassword(data[0..data_len]);
        std.c.free(raw);
    }
    @memset(data[0..data_len], 0);
    data[0] = if (is_twenty_byte != 0) 0x80 else 0x00;
    data[0] |= ipmiUid(user_id);
    data[1] = 0x03 & operation;
    if (password) |pw| {
        var copy_len = std.mem.len(pw);
        if (copy_len > data_len - 2) {
            copy_len = data_len - 2;
        } else if (copy_len < 1) {
            copy_len = 0;
        }
        @memcpy(data[2 .. 2 + copy_len], pw[0..copy_len]);
    }

    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = cmd_set_user_password;
    req.msg.data = data;
    req.msg.data_len = data_len;
    const rsp = sendrecv(intf, &req);
    return (rsp orelse return -1).ccode;
}

// ---------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------

/// `dump_user_access()`'s function level `static int printed_header`.
var printed_header = false;

const list_header = "ID  Name\t     Callin  Link Auth\tIPMI Msg   Channel Priv Limit\n";
const ListOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writePadded(writer: *std.Io.Writer, text: []const u8, width: usize) std.Io.Writer.Error!void {
    try writer.writeAll(text);
    try writer.writeAll("                 "[0..width -| text.len]);
}

fn dumpUserAccess(writer: *std.Io.Writer, user_name: [*:0]const u8, user_access: *const UserAccess, privilege: []const u8, header: *bool) std.Io.Writer.Error!void {
    if (!header.*) {
        try writer.writeAll(list_header);
        header.* = true;
    }
    var id_buf: [3]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{d}", .{user_access.user_id}) catch unreachable;
    try writePadded(writer, id, 4);
    try writePadded(writer, std.mem.span(user_name), 17);
    try writePadded(writer, if (user_access.callin_callback != 0) "false" else "true ", 8);
    try writePadded(writer, if (user_access.link_auth != 0) "true " else "false", 11);
    try writePadded(writer, if (user_access.ipmi_messaging != 0) "true " else "false", 11);
    try writer.writeAll(privilege);
    try writer.writeByte('\n');
}

fn dumpUserAccessCsv(writer: *std.Io.Writer, user_name: [*:0]const u8, user_access: *const UserAccess, privilege: []const u8) std.Io.Writer.Error!void {
    try writer.print("{d},{s},{s},{s},{s},", .{
        user_access.user_id,
        std.mem.span(user_name),
        if (user_access.callin_callback != 0) "false" else "true",
        if (user_access.link_auth != 0) "true" else "false",
        if (user_access.ipmi_messaging != 0) "true" else "false",
    });
    try writer.writeAll(privilege);
    try writer.writeByte('\n');
}

fn emitUserListRow(writer: *std.Io.Writer, csv: bool, user_name: [*:0]const u8, user_access: *const UserAccess, header: *bool, preflush: anytype) ListOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    const privilege = std.mem.span(c.val2str(user_access.privilege_limit, c.ipmi_privlvl_vals));
    if (csv) {
        dumpUserAccessCsv(writer, user_name, user_access, privilege) catch return error.StdoutWriteFailed;
    } else {
        dumpUserAccess(writer, user_name, user_access, privilege, header) catch return error.StdoutWriteFailed;
    }
    writer.flush() catch return error.StdoutFlushFailed;
}

/// `ipmi_print_user_list()`: list IPMI users and their ACLs for one channel.
///
/// Returns 0 on success and -1 on error.
fn printUserList(intf: *Intf, channel_number: u8) c_int {
    var user_access = std.mem.zeroes(UserAccess);
    var user_name = std.mem.zeroes(UserName);
    var ccode: c_int = 0;
    var current_user_id: u8 = 1;
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    while (true) {
        user_access = std.mem.zeroes(UserAccess);
        user_access.user_id = current_user_id;
        user_access.channel = channel_number;
        ccode = getUserAccess(intf, &user_access);
        if (c.eval_ccode(ccode) != 0) {
            return -1;
        }
        user_name = std.mem.zeroes(UserName);
        user_name.user_id = current_user_id;
        ccode = getUserName(intf, &user_name);
        if (ccode == 0xcc) {
            user_name.user_id = current_user_id;
            @memset(user_name.user_name[0..17], 0);
        } else if (c.eval_ccode(ccode) != 0) {
            return -1;
        }
        const name: [*:0]const u8 = @ptrCast(&user_name.user_name);
        emitUserListRow(&stdout.interface, c.csv_output != 0, name, &user_access, &printed_header, stdout_io.trySyncC) catch |err| {
            switch (err) {
                error.CStdoutFlushFailed => log.print(log.Level.err, "User list stdout C preflush failed (errno %d)", .{std.c._errno().*}),
                error.StdoutWriteFailed => log.print(log.Level.err, "User list stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
                error.StdoutFlushFailed => log.print(log.Level.err, "User list stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            }
            return -1;
        };
        current_user_id +%= 1;
        if (!(current_user_id <= user_access.max_user_ids and
            current_user_id <= uid_max)) break;
    }
    return 0;
}

test "list stdout matches libc byte widths, access bits and privilege fallbacks" {
    const cases = [_]struct {
        name: [*:0]const u8,
        id: u8,
        callin: u8,
        link: u8,
        messaging: u8,
        privilege_text: [*:0]const u8,
    }{
        .{ .name = "", .id = 1, .callin = 0, .link = 0, .messaging = 0, .privilege_text = "Unknown (0x00)" },
        .{ .name = "a", .id = 9, .callin = 0x40, .link = 0x20, .messaging = 0x10, .privilege_text = "ADMINISTRATOR" },
        .{ .name = "0123456789abcdef", .id = 10, .callin = 0, .link = 0x20, .messaging = 0, .privilege_text = "Unknown (0x06)" },
        .{ .name = "\x80x", .id = 63, .callin = 0x40, .link = 0, .messaging = 0x10, .privilege_text = "NO ACCESS" },
    };
    for (cases) |case| {
        var access = std.mem.zeroes(UserAccess);
        access.user_id = case.id;
        access.callin_callback = case.callin;
        access.link_auth = case.link;
        access.ipmi_messaging = case.messaging;
        for ([_]bool{ false, true }) |csv| {
            var expected: [256]u8 = undefined;
            const n = if (csv)
                c.snprintf(&expected, expected.len, "%d,%s,%s,%s,%s,%s\n", @as(c_int, case.id), case.name, @as([*:0]const u8, if (case.callin != 0) "false" else "true"), @as([*:0]const u8, if (case.link != 0) "true" else "false"), @as([*:0]const u8, if (case.messaging != 0) "true" else "false"), case.privilege_text)
            else
                c.snprintf(&expected, expected.len, "%-4d%-17s%-8s%-11s%-11s%-s\n", @as(c_int, case.id), case.name, @as([*:0]const u8, if (case.callin != 0) "false" else "true "), @as([*:0]const u8, if (case.link != 0) "true " else "false"), @as([*:0]const u8, if (case.messaging != 0) "true " else "false"), case.privilege_text);
            try std.testing.expect(n >= 0 and @as(usize, @intCast(n)) < expected.len);
            var storage: [256]u8 = undefined;
            var writer = std.Io.Writer.fixed(&storage);
            var header = true;
            if (csv) {
                try dumpUserAccessCsv(&writer, case.name, &access, std.mem.span(case.privilege_text));
            } else {
                try dumpUserAccess(&writer, case.name, &access, std.mem.span(case.privilege_text), &header);
            }
            try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
        }
    }
}

test "list stdout propagates preflush, header, row and final flush failures" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var access = std.mem.zeroes(UserAccess);
    access.user_id = 2;
    access.privilege_limit = 6;
    var header = false;
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitUserListRow(&writer, false, "alice", &access, &header, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try std.testing.expect(!header);

    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitUserListRow(&early, false, "alice", &access, &header, Stub.preflushOk));
    try std.testing.expect(!header);

    var short: [list_header.len + 8]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitUserListRow(&late, false, "alice", &access, &header, Stub.preflushOk));
    try std.testing.expect(header);
    try std.testing.expectEqualStrings(list_header ++ "2   alic", late.buffered());

    var csv_short: ["2,alice,".len]u8 = undefined;
    var csv_writer = std.Io.Writer.fixed(&csv_short);
    try std.testing.expectError(error.StdoutWriteFailed, emitUserListRow(&csv_writer, true, "alice", &access, &header, Stub.preflushOk));
    try std.testing.expectEqualStrings("2,alice,", csv_writer.buffered());

    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitUserListRow(&writer, true, "alice", &access, &header, Stub.preflushOk));
    try std.testing.expectEqualStrings("2,alice,true,false,false,\n", writer.buffered());
    try std.testing.expectError(error.CStdoutFlushFailed, emitUserListRow(&writer, true, "bob", &access, &header, Stub.preflushFail));
    try std.testing.expectEqualStrings("2,alice,true,false,false,\n", writer.buffered());
}

test "list stdout keeps header once across invocations and orders C output between rows" {
    const Exports = struct {
        var csv_output: c_int = 0;
        fn evalCcode(ccode: c_int) callconv(.c) c_int {
            return if (ccode == 0) 0 else -1;
        }
    };
    comptime {
        @export(&Exports.csv_output, .{ .name = "csv_output" });
        @export(&Exports.evalCcode, .{ .name = "eval_ccode" });
    }
    const Stub = struct {
        var requests: usize = 0;
        var response: Response = std.mem.zeroes(Response);
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            requests += 1;
            response = std.mem.zeroes(Response);
            if (req.msg.cmd == cmd_get_user_access) {
                response.data_len = 4;
                response.data[0] = 1;
                response.data[3] = 0x34;
            } else if (req.msg.cmd == cmd_get_user_name) {
                response.data_len = 16;
                response.data[0] = 'r';
            } else return null;
            return &response;
        }
    };
    const old_header = printed_header;
    const old_csv = c.csv_output;
    defer {
        printed_header = old_header;
        c.csv_output = old_csv;
    }
    printed_header = false;
    Stub.requests = 0;
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;

    const stdout_fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved_fd = c.dup(stdout_fd);
    try std.testing.expect(saved_fd >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved_fd, stdout_fd);
        _ = c.close(saved_fd);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(stdout_fd, c.dup2(fds[1], stdout_fd));
    _ = c.close(fds[1]);

    c.csv_output = 0;
    _ = c.printf("before|");
    try std.testing.expectEqual(@as(c_int, 0), printUserList(&intf, 1));
    _ = c.printf("|between|");
    c.csv_output = 1;
    try std.testing.expectEqual(@as(c_int, 0), printUserList(&intf, 1));
    _ = c.printf("|again|");
    c.csv_output = 0;
    try std.testing.expectEqual(@as(c_int, 0), printUserList(&intf, 1));
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(stdout_fd, c.dup2(saved_fd, stdout_fd));

    var captured: [512]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    // The ABI test binary stubs val2str as empty; the CLI goldens check the real lookup.
    try std.testing.expectEqualStrings(
        "before|" ++ list_header ++
            "1   r                true    true       true       \n" ++
            "|between|1,r,true,true,true,\n" ++
            "|again|1   r                true    true       true       \n" ++
            "|after\n",
        captured[0..@intCast(length)],
    );
    try std.testing.expectEqual(@as(usize, 6), Stub.requests);
}

/// `ipmi_print_user_summary()`: print user statistics for one channel.
///
/// Returns 0 on success and -1 on error.
const SummaryOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writeUserSummary(writer: *std.Io.Writer, csv: bool, access: *const UserAccess) std.Io.Writer.Error!void {
    if (csv) {
        try writer.print("{d},{d},{d}\n", .{
            access.max_user_ids, access.enabled_user_ids, access.fixed_user_ids,
        });
    } else {
        try writer.print(
            "Maximum IDs\t    : {d}\n" ++
                "Enabled User Count  : {d}\n" ++
                "Fixed Name Count    : {d}\n",
            .{ access.max_user_ids, access.enabled_user_ids, access.fixed_user_ids },
        );
    }
}

fn emitUserSummary(writer: *std.Io.Writer, csv: bool, access: *const UserAccess, preflush: anytype) SummaryOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeUserSummary(writer, csv, access) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn printUserSummary(intf: *Intf, channel_number: u8) c_int {
    var user_access = std.mem.zeroes(UserAccess);
    user_access.channel = channel_number;
    user_access.user_id = 1;
    const ccode = getUserAccess(intf, &user_access);
    if (c.eval_ccode(ccode) != 0) {
        return -1;
    }
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    emitUserSummary(&stdout.interface, c.csv_output != 0, &user_access, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "User summary stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "User summary stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "User summary stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
    return 0;
}

test "summary stdout matches C decimal formatting for csv and human counters" {
    const counts = [_][3]u8{ .{ 0, 0, 0 }, .{ 1, 17, 42 }, .{ 63, 62, 61 } };
    for (counts) |fields| {
        var access = std.mem.zeroes(UserAccess);
        access.max_user_ids = fields[0];
        access.enabled_user_ids = fields[1];
        access.fixed_user_ids = fields[2];
        for ([_]bool{ false, true }) |csv| {
            var expected: [128]u8 = undefined;
            const n = if (csv)
                c.snprintf(&expected, expected.len, "%u,%u,%u\n", @as(c_uint, fields[0]), @as(c_uint, fields[1]), @as(c_uint, fields[2]))
            else
                c.snprintf(
                    &expected,
                    expected.len,
                    "Maximum IDs\t    : %u\n" ++
                        "Enabled User Count  : %u\n" ++
                        "Fixed Name Count    : %u\n",
                    @as(c_uint, fields[0]),
                    @as(c_uint, fields[1]),
                    @as(c_uint, fields[2]),
                );
            try std.testing.expect(n >= 0 and @as(usize, @intCast(n)) < expected.len);
            var storage: [128]u8 = undefined;
            var writer = std.Io.Writer.fixed(&storage);
            try writeUserSummary(&writer, csv, &access);
            try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
        }
    }
}

test "summary stdout propagates preflush, early, late and final flush errors" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var access = std.mem.zeroes(UserAccess);
    access.max_user_ids = 63;
    access.enabled_user_ids = 62;
    access.fixed_user_ids = 61;
    var storage: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitUserSummary(&writer, true, &access, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitUserSummary(&early, true, &access, Stub.preflushOk));

    const prefix = "Maximum IDs\t    : 63\nEnabled User Count  : 62\n";
    var short: [prefix.len]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitUserSummary(&late, false, &access, Stub.preflushOk));
    try std.testing.expectEqualStrings(prefix, late.buffered());

    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitUserSummary(&writer, true, &access, Stub.preflushOk));
    try std.testing.expectEqualStrings("63,62,61\n", writer.buffered());
}

test "summary stdout orders buffered C output before Zig and subsequent C output" {
    const stdout_fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved_fd = c.dup(stdout_fd);
    try std.testing.expect(saved_fd >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved_fd, stdout_fd);
        _ = c.close(saved_fd);
    }

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(stdout_fd, c.dup2(fds[1], stdout_fd));
    _ = c.close(fds[1]);

    var access = std.mem.zeroes(UserAccess);
    access.max_user_ids = 63;
    access.enabled_user_ids = 62;
    access.fixed_user_ids = 61;
    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitUserSummary(&stdout.interface, true, &access, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(stdout_fd, c.dup2(saved_fd, stdout_fd));

    var captured: [128]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings("before|63,62,61\n|after\n", captured[0..@intCast(length)]);
}

// ---------------------------------------------------------------------------
// Set User Name / Test Password
// ---------------------------------------------------------------------------

/// `ipmi_user_set_username()`.
///
/// Returns 0 on success and -1 on error.
fn userSetUsername(intf: *Intf, user_id_in: u8, name: [*:0]const u8) c_int {
    var req: Request = undefined;
    var msg_data: [17]u8 = undefined;

    // Ensure there is space for the name in the request message buffer.
    const name_len = std.mem.len(name);
    if (name_len >= msg_data.len) {
        return -1;
    }

    req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app; // 0x06
    req.msg.cmd = cmd_set_user_name; // 0x45
    req.msg.data = &msg_data;
    req.msg.data_len = msg_data.len;
    @memset(&msg_data, 0);

    const user_id = ipmiUid(user_id_in);

    // The channel number will remain constant throughout this function.
    msg_data[0] = user_id;
    @memcpy(msg_data[1 .. 1 + name_len], name[0..name_len]);

    const rsp = sendrecv(intf, &req) orelse {
        log.print(
            log.Level.err,
            "Set User Name command failed (user %d, name %s)",
            .{ @as(c_int, user_id), name },
        );
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(
            log.Level.err,
            "Set User Name command failed (user %d, name %s): %s",
            .{
                @as(c_int, user_id),
                name,
                c.val2str(rsp.ccode, c.completion_code_vals),
            },
        );
        return -1;
    }

    return 0;
}

/// `ipmi_user_test_password()`: run Set User Password with the test operation
/// and interpret the result.
const PasswordTestOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writePasswordTestResult(writer: *std.Io.Writer, ret: c_int) std.Io.Writer.Error!void {
    try writer.writeAll(switch (ret) {
        0 => "Success\n",
        0x80 => "Failure: password incorrect\n",
        0x81 => "Failure: wrong password size\n",
        else => "Unknown error\n",
    });
}

fn emitPasswordTestResult(writer: *std.Io.Writer, ret: c_int, preflush: anytype) PasswordTestOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writePasswordTestResult(writer, ret) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn userTestPassword(
    intf: *Intf,
    user_id: u8,
    password: ?[*:0]const u8,
    is_twenty_byte_password: u8,
) c_int {
    const ret = setUserPassword(
        intf,
        user_id,
        password_test_password,
        password,
        is_twenty_byte_password,
    );

    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    emitPasswordTestResult(&stdout.interface, ret, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "User password test stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "User password test stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "User password test stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };

    return if (ret == 0) 0 else -1;
}

test "password test stdout matches C results" {
    const cases = [_]struct { ret: c_int, text: [*:0]const u8 }{
        .{ .ret = 0, .text = "Success" },
        .{ .ret = 0x80, .text = "Failure: password incorrect" },
        .{ .ret = 0x81, .text = "Failure: wrong password size" },
        .{ .ret = 0x82, .text = "Unknown error" },
        .{ .ret = -1, .text = "Unknown error" },
    };
    for (cases) |case| {
        var expected: [64]u8 = undefined;
        const n = c.snprintf(&expected, expected.len, "%s\n", case.text);
        try std.testing.expect(n >= 0 and @as(usize, @intCast(n)) < expected.len);
        var storage: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try writePasswordTestResult(&writer, case.ret);
        try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
    }
}

test "password test stdout propagates preflush, write and final flush errors" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitPasswordTestResult(&writer, 0, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitPasswordTestResult(&early, 0, Stub.preflushOk));
    var short: [7]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitPasswordTestResult(&late, 0x80, Stub.preflushOk));
    try std.testing.expectEqualStrings("Failure", late.buffered());
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitPasswordTestResult(&writer, 0, Stub.preflushOk));
    try std.testing.expectEqualStrings("Success\n", writer.buffered());
}

test "password test stdout orders buffered C output before and after Zig" {
    const stdout_fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved_fd = c.dup(stdout_fd);
    try std.testing.expect(saved_fd >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved_fd, stdout_fd);
        _ = c.close(saved_fd);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(stdout_fd, c.dup2(fds[1], stdout_fd));
    _ = c.close(fds[1]);

    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitPasswordTestResult(&stdout.interface, 0, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(stdout_fd, c.dup2(saved_fd, stdout_fd));
    var captured: [64]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings("before|Success\n|after\n", captured[0..@intCast(length)]);
}

// ---------------------------------------------------------------------------
// Usage and the password prompt
// ---------------------------------------------------------------------------

/// `print_user_usage()`.
fn printUserUsage() void {
    log.print(log.Level.notice, "User Commands:", .{});
    log.print(log.Level.notice, "               summary      [<channel number>]", .{});
    log.print(log.Level.notice, "               list         [<channel number>]", .{});
    log.print(log.Level.notice, "               set name     <user id> <username>", .{});
    log.print(log.Level.notice, "               set password <user id> [<password> [<16|20>]]", .{});
    log.print(log.Level.notice, "               disable      <user id>", .{});
    log.print(log.Level.notice, "               enable       <user id>", .{});
    log.print(log.Level.notice, "               priv         <user id> <privilege level> [<channel number>]", .{});
    log.print(log.Level.notice, "                     Privilege levels:", .{});
    log.print(log.Level.notice, "                      * 0x1 - Callback", .{});
    log.print(log.Level.notice, "                      * 0x2 - User", .{});
    log.print(log.Level.notice, "                      * 0x3 - Operator", .{});
    log.print(log.Level.notice, "                      * 0x4 - Administrator", .{});
    log.print(log.Level.notice, "                      * 0x5 - OEM Proprietary", .{});
    log.print(log.Level.notice, "                      * 0xF - No Access", .{});
    log.print(log.Level.notice, "", .{});
    log.print(log.Level.notice, "               test         <user id> <16|20> [<password>]", .{});
    log.print(log.Level.notice, "", .{});
}

/// `ipmi_user_build_password_prompt()`'s function level `static char
/// prompt[128]`.
var prompt_buf: [128]u8 = undefined;

/// `ipmi_user_build_password_prompt()`.
fn buildPasswordPrompt(user_id: u8) callconv(.c) [*c]const u8 {
    @memset(&prompt_buf, 0);
    _ = c.snprintf(&prompt_buf, 128, "Password for user %d: ", @as(c_int, user_id));
    return &prompt_buf;
}

/// `ask_password()`: prompt for a password.
///
/// The returned pointer is `getpass()`'s static buffer, so two consecutive
/// calls hand back the same storage.
fn askPassword(user_id: u8) callconv(.c) [*c]u8 {
    const password_prompt = buildPasswordPrompt(user_id);
    if (@hasDecl(c, "getpassphrase")) {
        return c.getpassphrase(password_prompt);
    } else {
        return c.getpass(password_prompt);
    }
}

// ---------------------------------------------------------------------------
// Subcommand handlers
// ---------------------------------------------------------------------------

/// `ipmi_user_summary()`.
fn userSummary(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var channel: u8 = undefined;
    if (argc == 1) {
        channel = 0x0e; // Ask about the current channel.
    } else if (argc == 2) {
        if (c.is_ipmi_channel_num(argv[1], &channel) != 0) {
            return -1;
        }
    } else {
        printUserUsage();
        return -1;
    }
    return printUserSummary(intf, channel);
}

/// `ipmi_user_list()`.
fn userList(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var channel: u8 = undefined;
    if (argc == 1) {
        channel = 0x0e; // Ask about the current channel.
    } else if (argc == 2) {
        if (c.is_ipmi_channel_num(argv[1], &channel) != 0) {
            return -1;
        }
    } else {
        printUserUsage();
        return -1;
    }
    return printUserList(intf, channel);
}

/// `ipmi_user_test()`.
fn userTest(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var password: ?[*:0]const u8 = null;
    var password_length: i32 = 0;
    var user_id: u8 = 0;
    // A little irritating, isn't it.
    if (argc != 3 and argc != 4) {
        printUserUsage();
        return -1;
    }
    if (c.is_ipmi_user_id(argv[1], &user_id) != 0) {
        return -1;
    }
    if (c.str2int(argv[2], &password_length) != 0 or
        (password_length != 16 and password_length != 20))
    {
        log.print(log.Level.err, "Given password length '%s' is invalid.", .{argv[2]});
        log.print(log.Level.err, "Expected value is either 16 or 20.", .{});
        return -1;
    }
    if (argc == 3) {
        // We need to prompt for a password.
        password = askPassword(user_id);
        if (password == null) {
            log.print(log.Level.err, "ipmitool: malloc failure", .{});
            return -1;
        }
    } else {
        password = argv[3];
    }
    return userTestPassword(
        intf,
        user_id,
        password,
        @intFromBool(password_length == 20),
    );
}

/// `ipmi_user_priv()`.
fn userPriv(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var user_access = std.mem.zeroes(UserAccess);
    var ccode: c_int = 0;

    if (argc != 3 and argc != 4) {
        printUserUsage();
        return -1;
    }
    if (argc == 4) {
        if (c.is_ipmi_channel_num(argv[3], &user_access.channel) != 0) {
            return -1;
        }
    } else {
        // Use channel running on.
        user_access.channel = 0x0e;
    }
    if (c.is_ipmi_user_priv_limit(argv[2], &user_access.privilege_limit) != 0 or
        c.is_ipmi_user_id(argv[1], &user_access.user_id) != 0)
    {
        return -1;
    }
    ccode = setUserAccess(intf, &user_access, 1);
    if (c.eval_ccode(ccode) != 0) {
        log.print(
            log.Level.err,
            "Set Privilege Level command failed (user %d)",
            .{@as(c_int, user_access.user_id)},
        );
        return -1;
    } else {
        _ = c.printf(
            "Set Privilege Level command successful (user %d)\n",
            @as(c_int, user_access.user_id),
        );
        return 0;
    }
}

/// `ipmi_user_mod()`: the `disable` and `enable` subcommands.
fn userMod(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var user_id: u8 = undefined;

    if (argc != 2) {
        printUserUsage();
        return -1;
    }
    if (c.is_ipmi_user_id(argv[1], &user_id) != 0) {
        return -1;
    }
    const operation: u8 = if (eql(argv[0], "disable"))
        password_disable_user
    else
        password_enable_user;

    const ccode: c_int = setUserPassword(intf, user_id, operation, null, 0);
    if (c.eval_ccode(ccode) != 0) {
        log.print(
            log.Level.err,
            "Set User Password command failed (user %d)",
            .{@as(c_int, user_id)},
        );
        return -1;
    }
    return 0;
}

/// `ipmi_user_password()`: the `set password` subcommand.
fn userPassword(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var password: ?[*:0]const u8 = null;
    var saved_password: [pw_max_len + 1]u8 = @splat(0);
    defer wipePassword(&saved_password);
    var ccode: c_int = 0;
    var password_type: u8 = pw_ipmi15_len;
    var user_id: u8 = 0;
    if (c.is_ipmi_user_id(argv[2], &user_id) != 0) {
        return -1;
    }

    if (argc == 3) {
        // We need to prompt for a password.
        password = askPassword(user_id);
        if (password == null) {
            log.print(log.Level.err, "ipmitool: malloc failure", .{});
            return -1;
        }
        const first_len = c.strnlen(password, pw_max_len + 1);
        if (first_len > pw_max_len) {
            log.print(log.Level.err, "Password is too long (> %d bytes)", .{@as(c_int, pw_max_len)});
            return -1;
        }
        @memcpy(saved_password[0..first_len], password.?[0..first_len]);
        saved_password[first_len] = 0;
        const tmp: ?[*:0]const u8 = askPassword(user_id);
        if (tmp == null) {
            log.print(log.Level.err, "ipmitool: malloc failure", .{});
            return -1;
        }
        const tmplen = c.strnlen(tmp, pw_max_len + 1);
        if (tmplen != first_len or !std.mem.eql(u8, saved_password[0..first_len], tmp.?[0..first_len])) {
            log.print(
                log.Level.err,
                "Passwords do not match or are longer than %d",
                .{@as(c_int, pw_max_len)},
            );
            return -1;
        }
        password = saved_password[0..first_len :0].ptr;
    } else {
        password = argv[3];
    }

    if (password == null) {
        log.print(log.Level.err, "Unable to parse password argument.", .{});
        return -1;
    }

    const password_len = c.strnlen(password, pw_max_len + 1);

    if (argc > 4) {
        if ((c.str2uchar(argv[4], &password_type) != 0) or
            (password_type != pw_ipmi15_len and password_type != pw_ipmi20_len))
        {
            log.print(log.Level.err, "Invalid password length '%s'", .{argv[4]});
            return -1;
        }
    } else if (password_len > pw_ipmi15_len) {
        password_type = pw_ipmi20_len;
    }

    if (password_len > password_type) {
        log.print(
            log.Level.err,
            "Password is too long (> %d bytes)",
            .{@as(c_int, password_type)},
        );
        return -1;
    }

    ccode = setUserPassword(
        intf,
        user_id,
        password_set_password,
        password,
        @intFromBool(password_type > pw_ipmi15_len),
    );
    if (c.eval_ccode(ccode) != 0) {
        log.print(
            log.Level.err,
            "Set User Password command failed (user %d)",
            .{@as(c_int, user_id)},
        );
        return -1;
    } else {
        _ = c.printf(
            "Set User Password command successful (user %d)\n",
            @as(c_int, user_id),
        );
        return 0;
    }
}

/// `ipmi_user_name()`: the `set name` subcommand.
fn userName(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var user_id: u8 = 0;
    if (argc != 4) {
        printUserUsage();
        return -1;
    }
    if (c.is_ipmi_user_id(argv[2], &user_id) != 0) {
        return -1;
    }
    if (std.mem.len(argv[3]) > 16) {
        log.print(log.Level.err, "Username is too long (> 16 bytes)", .{});
        return -1;
    }

    return userSetUsername(intf, user_id, argv[3]);
}

/// `ipmi_user_main()`: the `user` command.
fn userMain(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    if (argc == 0) {
        log.print(log.Level.err, "Not enough parameters given.", .{});
        printUserUsage();
        return -1;
    }
    if (eql(argv[0], "help")) {
        printUserUsage();
        return 0;
    } else if (eql(argv[0], "summary")) {
        return userSummary(intf, argc, argv);
    } else if (eql(argv[0], "list")) {
        return userList(intf, argc, argv);
    } else if (eql(argv[0], "test")) {
        return userTest(intf, argc, argv);
    } else if (eql(argv[0], "set")) {
        if (argc >= 3 and eql(argv[1], "password")) {
            return userPassword(intf, argc, argv);
        } else if (argc >= 2 and eql(argv[1], "name")) {
            return userName(intf, argc, argv);
        } else {
            printUserUsage();
            return -1;
        }
    } else if (eql(argv[0], "priv")) {
        return userPriv(intf, argc, argv);
    } else if (eql(argv[0], "disable") or eql(argv[0], "enable")) {
        return userMod(intf, argc, argv);
    } else {
        log.print(log.Level.err, "Invalid user command: '%s'\n", .{argv[0]});
        printUserUsage();
        return -1;
    }
}

// ---------------------------------------------------------------------------
// C ABI surface
// ---------------------------------------------------------------------------

pub fn exportSymbols() void {
    comptime {
        abi.assertCallSignature(@TypeOf(getUserAccess), @TypeOf(c._ipmi_get_user_access));
        @export(&getUserAccess, .{ .name = "_ipmi_get_user_access", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getUserName), @TypeOf(c._ipmi_get_user_name));
        @export(&getUserName, .{ .name = "_ipmi_get_user_name", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(setUserAccess), @TypeOf(c._ipmi_set_user_access));
        @export(&setUserAccess, .{ .name = "_ipmi_set_user_access", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(setUserPassword), @TypeOf(c._ipmi_set_user_password));
        @export(&setUserPassword, .{ .name = "_ipmi_set_user_password", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(userMain), @TypeOf(c.ipmi_user_main));
        @export(&userMain, .{ .name = "ipmi_user_main", .linkage = .strong });

        // The remaining nine symbols have external linkage but no prototype in
        // any header - they are bare globals declared only in
        // `lib/ipmi_user.c` - so there is no C declaration to assert against.
        @export(&buildPasswordPrompt, .{
            .name = "ipmi_user_build_password_prompt",
            .linkage = .strong,
        });
        @export(&askPassword, .{ .name = "ask_password", .linkage = .strong });
        @export(&userSummary, .{ .name = "ipmi_user_summary", .linkage = .strong });
        @export(&userList, .{ .name = "ipmi_user_list", .linkage = .strong });
        @export(&userTest, .{ .name = "ipmi_user_test", .linkage = .strong });
        @export(&userPriv, .{ .name = "ipmi_user_priv", .linkage = .strong });
        @export(&userMod, .{ .name = "ipmi_user_mod", .linkage = .strong });
        @export(&userPassword, .{ .name = "ipmi_user_password", .linkage = .strong });
        @export(&userName, .{ .name = "ipmi_user_name", .linkage = .strong });
    }
}
