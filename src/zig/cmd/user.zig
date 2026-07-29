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
//! * **`ask_password()` returns a pointer into `getpass()`'s static buffer.**
//!   That is what makes the confirmation loop in `ipmi_user_password()` a
//!   no-op: `password` and `tmp` alias, so `strncmp()` always reports a match.
//!   See issue #39.
//! * **Upstream defects are reproduced deliberately.**  See issue #39:
//!   - `ipmi_user_password()` reads the confirmation password twice into the
//!     same static buffer, so the "Passwords do not match" check can never
//!     fire.
//!   - `ipmi_user_password()` calls `strnlen(tmp, ...)` *before* testing `tmp`
//!     for NULL.
//!   - `ipmi_user_mod()` stores the `int` result of
//!     `_ipmi_set_user_password()` in a `uint8_t`, so the negative error
//!     returns are truncated to 0xFF/0xFC before `eval_ccode()` sees them and
//!     are misreported as completion codes.
//!   - `ipmi_user_set_username()` rejects names of 17 bytes or more, but
//!     `ipmi_user_name()` has already rejected anything over 16, so the guard
//!     is dead code.
//!
//! The `getpass()` prompt paths are not covered by the golden suite: `getpass()`
//! opens `/dev/tty` when one exists, so its behaviour depends on whether the
//! suite runs from a terminal.
//!
//! Everything this module needs from C - `printf`, `lprintf`, `val2str`,
//! `eval_ccode`, `getpass`, `str2int`, `str2uchar` and the `is_ipmi_*`
//! validators - is reached through the `ipmi_c` bridge.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
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
    std.c.free(raw);
    return (rsp orelse return -1).ccode;
}

// ---------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------

/// `dump_user_access()`'s function level `static int printed_header`.
var printed_header: c_int = 0;

fn dumpUserAccess(user_name: [*:0]const u8, user_access: *const UserAccess) void {
    if (printed_header == 0) {
        _ = c.printf("ID  Name\t     Callin  Link Auth\tIPMI Msg   " ++
            "Channel Priv Limit\n");
        printed_header = 1;
    }
    _ = c.printf(
        "%-4d%-17s%-8s%-11s%-11s%-s\n",
        @as(c_int, user_access.user_id),
        user_name,
        @as([*:0]const u8, if (user_access.callin_callback != 0) "false" else "true "),
        @as([*:0]const u8, if (user_access.link_auth != 0) "true " else "false"),
        @as([*:0]const u8, if (user_access.ipmi_messaging != 0) "true " else "false"),
        c.val2str(user_access.privilege_limit, c.ipmi_privlvl_vals),
    );
}

fn dumpUserAccessCsv(user_name: [*:0]const u8, user_access: *const UserAccess) void {
    _ = c.printf(
        "%d,%s,%s,%s,%s,%s\n",
        @as(c_int, user_access.user_id),
        user_name,
        @as([*:0]const u8, if (user_access.callin_callback != 0) "false" else "true"),
        @as([*:0]const u8, if (user_access.link_auth != 0) "true" else "false"),
        @as([*:0]const u8, if (user_access.ipmi_messaging != 0) "true" else "false"),
        c.val2str(user_access.privilege_limit, c.ipmi_privlvl_vals),
    );
}

/// `ipmi_print_user_list()`: list IPMI users and their ACLs for one channel.
///
/// Returns 0 on success and -1 on error.
fn printUserList(intf: *Intf, channel_number: u8) c_int {
    var user_access = std.mem.zeroes(UserAccess);
    var user_name = std.mem.zeroes(UserName);
    var ccode: c_int = 0;
    var current_user_id: u8 = 1;
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
        if (c.csv_output != 0) {
            dumpUserAccessCsv(name, &user_access);
        } else {
            dumpUserAccess(name, &user_access);
        }
        current_user_id +%= 1;
        if (!(current_user_id <= user_access.max_user_ids and
            current_user_id <= uid_max)) break;
    }
    return 0;
}

/// `ipmi_print_user_summary()`: print user statistics for one channel.
///
/// Returns 0 on success and -1 on error.
fn printUserSummary(intf: *Intf, channel_number: u8) c_int {
    var user_access = std.mem.zeroes(UserAccess);
    user_access.channel = channel_number;
    user_access.user_id = 1;
    const ccode = getUserAccess(intf, &user_access);
    if (c.eval_ccode(ccode) != 0) {
        return -1;
    }
    if (c.csv_output != 0) {
        _ = c.printf(
            "%u,%u,%u\n",
            @as(c_uint, user_access.max_user_ids),
            @as(c_uint, user_access.enabled_user_ids),
            @as(c_uint, user_access.fixed_user_ids),
        );
    } else {
        _ = c.printf("Maximum IDs\t    : %u\n", @as(c_uint, user_access.max_user_ids));
        _ = c.printf("Enabled User Count  : %u\n", @as(c_uint, user_access.enabled_user_ids));
        _ = c.printf("Fixed Name Count    : %u\n", @as(c_uint, user_access.fixed_user_ids));
    }
    return 0;
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
        c.lprintf(
            log.Level.err,
            "Set User Name command failed (user %d, name %s)",
            @as(c_int, user_id),
            name,
        );
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Set User Name command failed (user %d, name %s): %s",
            @as(c_int, user_id),
            name,
            c.val2str(rsp.ccode, c.completion_code_vals),
        );
        return -1;
    }

    return 0;
}

/// `ipmi_user_test_password()`: run Set User Password with the test operation
/// and interpret the result.
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

    switch (ret) {
        0 => _ = c.printf("Success\n"),
        0x80 => _ = c.printf("Failure: password incorrect\n"),
        0x81 => _ = c.printf("Failure: wrong password size\n"),
        else => _ = c.printf("Unknown error\n"),
    }

    return if (ret == 0) 0 else -1;
}

// ---------------------------------------------------------------------------
// Usage and the password prompt
// ---------------------------------------------------------------------------

/// `print_user_usage()`.
fn printUserUsage() void {
    c.lprintf(log.Level.notice, "User Commands:");
    c.lprintf(log.Level.notice, "               summary      [<channel number>]");
    c.lprintf(log.Level.notice, "               list         [<channel number>]");
    c.lprintf(log.Level.notice, "               set name     <user id> <username>");
    c.lprintf(log.Level.notice, "               set password <user id> [<password> [<16|20>]]");
    c.lprintf(log.Level.notice, "               disable      <user id>");
    c.lprintf(log.Level.notice, "               enable       <user id>");
    c.lprintf(log.Level.notice, "               priv         <user id> <privilege level> [<channel number>]");
    c.lprintf(log.Level.notice, "                     Privilege levels:");
    c.lprintf(log.Level.notice, "                      * 0x1 - Callback");
    c.lprintf(log.Level.notice, "                      * 0x2 - User");
    c.lprintf(log.Level.notice, "                      * 0x3 - Operator");
    c.lprintf(log.Level.notice, "                      * 0x4 - Administrator");
    c.lprintf(log.Level.notice, "                      * 0x5 - OEM Proprietary");
    c.lprintf(log.Level.notice, "                      * 0xF - No Access");
    c.lprintf(log.Level.notice, "");
    c.lprintf(log.Level.notice, "               test         <user id> <16|20> [<password>]");
    c.lprintf(log.Level.notice, "");
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
        c.lprintf(log.Level.err, "Given password length '%s' is invalid.", argv[2]);
        c.lprintf(log.Level.err, "Expected value is either 16 or 20.");
        return -1;
    }
    if (argc == 3) {
        // We need to prompt for a password.
        password = askPassword(user_id);
        if (password == null) {
            c.lprintf(log.Level.err, "ipmitool: malloc failure");
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
        c.lprintf(
            log.Level.err,
            "Set Privilege Level command failed (user %d)",
            @as(c_int, user_access.user_id),
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
///
/// `ccode` is a `uint8_t` in C, so the negative returns of
/// `_ipmi_set_user_password()` are truncated before `eval_ccode()` sees them.
/// Reproduced faithfully; see issue #39.
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

    const ccode: u8 = @truncate(@as(c_uint, @bitCast(
        setUserPassword(intf, user_id, operation, null, 0),
    )));
    if (c.eval_ccode(ccode) != 0) {
        c.lprintf(
            log.Level.err,
            "Set User Password command failed (user %d)",
            @as(c_int, user_id),
        );
        return -1;
    }
    return 0;
}

/// `ipmi_user_password()`: the `set password` subcommand.
fn userPassword(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var password: ?[*:0]const u8 = null;
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
            c.lprintf(log.Level.err, "ipmitool: malloc failure");
            return -1;
        }
        const tmp: ?[*:0]const u8 = askPassword(user_id);
        const tmplen = c.strnlen(tmp, pw_max_len + 1);
        if (tmp == null) {
            c.lprintf(log.Level.err, "ipmitool: malloc failure");
            return -1;
        }
        if (c.strncmp(password, tmp, tmplen) != 0) {
            c.lprintf(
                log.Level.err,
                "Passwords do not match or are longer than %d",
                @as(c_int, pw_max_len),
            );
            return -1;
        }
    } else {
        password = argv[3];
    }

    if (password == null) {
        c.lprintf(log.Level.err, "Unable to parse password argument.");
        return -1;
    }

    const password_len = c.strnlen(password, pw_max_len + 1);

    if (argc > 4) {
        if ((c.str2uchar(argv[4], &password_type) != 0) or
            (password_type != pw_ipmi15_len and password_type != pw_ipmi20_len))
        {
            c.lprintf(log.Level.err, "Invalid password length '%s'", argv[4]);
            return -1;
        }
    } else if (password_len > pw_ipmi15_len) {
        password_type = pw_ipmi20_len;
    }

    if (password_len > password_type) {
        c.lprintf(
            log.Level.err,
            "Password is too long (> %d bytes)",
            @as(c_int, password_type),
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
        c.lprintf(
            log.Level.err,
            "Set User Password command failed (user %d)",
            @as(c_int, user_id),
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
        c.lprintf(log.Level.err, "Username is too long (> 16 bytes)");
        return -1;
    }

    return userSetUsername(intf, user_id, argv[3]);
}

/// `ipmi_user_main()`: the `user` command.
fn userMain(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    if (argc == 0) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
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
        c.lprintf(log.Level.err, "Invalid user command: '%s'\n", argv[0]);
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
