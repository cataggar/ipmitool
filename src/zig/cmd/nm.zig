//! Node Manager commands from `lib/ipmi_dcmi.c`, over OEM netfn 0x2e.
//! Kept separately from DCMI to keep the two protocol parsers independent.
const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Response = ipmi.Response;
const Request = ipmi.Request;

const Item = struct { value: u8, text: [*:0]const u8, help: [*:0]const u8 = "" };
const commands = [_]Item{
    .{ .value = 0, .text = "discover", .help = "Discover Node Manager" },
    .{ .value = 1, .text = "capability", .help = "Get Node Manager Capabilities" },
    .{ .value = 2, .text = "control", .help = "Enable/Disable Policy Control" },
    .{ .value = 3, .text = "policy", .help = "Add/Remove Policies" },
    .{ .value = 4, .text = "statistics", .help = "Get Statistics" },
    .{ .value = 5, .text = "power", .help = "Set Power Draw Range" },
    .{ .value = 6, .text = "suspend", .help = "Set/Get Policy suspend periods" },
    .{ .value = 7, .text = "reset", .help = "Reset Statistics" },
    .{ .value = 8, .text = "alert", .help = "Set/Get/Clear Alert destination" },
    .{ .value = 9, .text = "threshold", .help = "Set/Get Alert Thresholds" },
};
const domains = [_]Item{
    .{ .value = 0, .text = "platform" }, .{ .value = 1, .text = "CPU" },
    .{ .value = 2, .text = "Memory" },   .{ .value = 3, .text = "protection" },
    .{ .value = 4, .text = "I/O" },
};
const versions = [_]Item{
    .{ .value = 1, .text = "1.0" }, .{ .value = 2, .text = "1.5" },
    .{ .value = 3, .text = "2.0" }, .{ .value = 4, .text = "2.5" },
    .{ .value = 5, .text = "3.0" },
};
const caps_options = [_]Item{
    .{ .value = 1, .text = "domain", .help = "<platform|CPU|Memory> (default is platform)" },
    .{ .value = 2, .text = "inlet", .help = "Inlet temp trigger" },
    .{ .value = 3, .text = "missing", .help = "Missing Power reading trigger" },
    .{ .value = 4, .text = "reset", .help = "Time after Host reset trigger" },
    .{ .value = 5, .text = "boot", .help = "Boot time policy" },
};
const ctl_actions = [_]Item{
    .{ .value = 1, .text = "enable", .help = "<control scope>" },
    .{ .value = 0, .text = "disable", .help = "<control scope>" },
};
const ctl_scope = [_]Item{
    .{ .value = 0, .text = "global" },
    .{ .value = 2, .text = "per_domain", .help = "<platform|CPU|Memory> (default is platform)" },
    .{ .value = 4, .text = "per_policy", .help = "<0-255>" },
};
const policy_actions = [_]Item{
    .{ .value = 0, .text = "get", .help = "nm policy get policy_id <0-255> [domain <platform|CPU|Memory>]" },
    .{ .value = 4, .text = "add", .help = "nm policy add policy_id <0-255> [domain <platform|CPU|Memory>] correction auto|soft|hard power <watts> | inlet <temp> trig_lim <param> stats <seconds> enable|disable" },
    .{ .value = 5, .text = "remove", .help = "nm policy remove policy_id <0-255> [domain <platform|CPU|Memory>]" },
    .{ .value = 6, .text = "limiting", .help = "nm policy limiting [domain <platform|CPU|Memory>]" },
};
const policy_opts = [_]Item{
    .{ .value = 1, .text = "enable" },                                              .{ .value = 2, .text = "disable" },
    .{ .value = 3, .text = "domain" },                                              .{ .value = 4, .text = "inlet", .help = "inlet air temp full limiting (SCRAM)" },
    .{ .value = 6, .text = "correction", .help = "auto, soft, hard" },              .{ .value = 8, .text = "power", .help = "power limit in watts" },
    .{ .value = 9, .text = "trig_lim", .help = "time to send alert" },              .{ .value = 10, .text = "stats", .help = "moving window averaging time" },
    .{ .value = 11, .text = "policy_id", .help = "policy number" },                 .{ .value = 12, .text = "volatile", .help = "save policy in volatiel memory" },
    .{ .value = 13, .text = "cores_off", .help = "at boot time, disable N cores" },
};
const triggers = [_]Item{
    .{ .value = 0, .text = "No trigger, use Power Limit" },             .{ .value = 1, .text = "Inlet temp trigger" },
    .{ .value = 2, .text = "Missing Power reading trigger" },           .{ .value = 3, .text = "Time after Host reset trigger" },
    .{ .value = 4, .text = "number of cores to disable at boot time" },
};
const correction = [_]Item{ .{ .value = 0, .text = "auto" }, .{ .value = 1, .text = "soft" }, .{ .value = 2, .text = "hard" } };
const correction_results = [_]Item{ .{ .value = 0, .text = "no T-state use" }, .{ .value = 1, .text = "no T-state use" }, .{ .value = 2, .text = "use T-states" } };
const exceptions = [_]Item{ .{ .value = 0, .text = "none" }, .{ .value = 1, .text = "alert" }, .{ .value = 2, .text = "shutdown" } };
const stats_opts = [_]Item{
    .{ .value = 1, .text = "domain", .help = "<platform|CPU|Memory> (default is platform)" },
    .{ .value = 2, .text = "policy_id", .help = "<0-255>" },
};
const stats_modes = [_]Item{
    .{ .value = 1, .text = "power", .help = "global power" },                          .{ .value = 2, .text = "temps", .help = "inlet temperature" },
    .{ .value = 0x11, .text = "policy_power", .help = "per policy power" },            .{ .value = 0x12, .text = "policy_temps", .help = "per policy inlet temp" },
    .{ .value = 0x13, .text = "policy_throt", .help = "per policy throttling stats" }, .{ .value = 0x1b, .text = "requests", .help = "unhandled requests" },
    .{ .value = 0x1c, .text = "response", .help = "response time" },                   .{ .value = 0x1d, .text = "cpu_throttling", .help = "CPU throttling" },
    .{ .value = 0x1e, .text = "mem_throttling", .help = "memory throttling" },         .{ .value = 0x1f, .text = "comm_fail", .help = "host communication failures" },
};
const reset_modes = [_]Item{
    .{ .value = 0, .text = "global" },        .{ .value = 1, .text = "per_policy" },
    .{ .value = 0x1b, .text = "requests" },   .{ .value = 0x1c, .text = "response" },
    .{ .value = 0x1d, .text = "throttling" }, .{ .value = 0x1e, .text = "memory" },
    .{ .value = 0x1f, .text = "comm" },
};
const range_opts = [_]Item{
    .{ .value = 1, .text = "domain", .help = "domain <platform|CPU|Memory> (default is platform)" },
    .{ .value = 2, .text = "min", .help = "min <integer value>" },
    .{ .value = 3, .text = "max", .help = "max <integer value>" },
};
const alert_actions = [_]Item{
    .{ .value = 1, .text = "set", .help = "nm alert set chan <chan> dest <dest> string <string>" },
    .{ .value = 2, .text = "get", .help = "nm alert get" },
    .{ .value = 3, .text = "clear", .help = "nm alert clear dest <dest>" },
};
const alert_opts = [_]Item{
    .{ .value = 1, .text = "chan", .help = "chan <channel>" },
    .{ .value = 2, .text = "dest", .help = "dest <destination>" },
    .{ .value = 3, .text = "string", .help = "string <string>" },
};
const threshold_actions = [_]Item{
    .{ .value = 1, .text = "set", .help = "nm thresh set [domain <platform|CPU|Memory>] policy_id <policy> thresh_array" },
    .{ .value = 2, .text = "get", .help = "nm thresh get [domain <platform|CPU|Memory>] policy_id <policy>" },
};
const suspend_actions = [_]Item{
    .{ .value = 1, .text = "set", .help = "nm suspend set [domain <platform|CPU|Memory]> policy_id <policy> <start> <stop> <pattern>" },
    .{ .value = 2, .text = "get", .help = "nm suspend get [domain <platform|CPU|Memory]> policy_id <policy>" },
};
const nm_ccodes = [_]c.struct_valstr{
    .{ .val = 0x80, .str = "Policy ID Invalid" },                                  .{ .val = 0x81, .str = "Domain ID Invalid" },
    .{ .val = 0x82, .str = "Unknown policy trigger type" },                        .{ .val = 0x84, .str = "Power Limit out of range" },
    .{ .val = 0x85, .str = "Correction Time out of range" },                       .{ .val = 0x86, .str = "Policy Trigger value out of range" },
    .{ .val = 0x88, .str = "Invalid Mode" },                                       .{ .val = 0x89, .str = "Statistics Reporting Period out of range" },
    .{ .val = 0x8b, .str = "Invalid value for Aggressive CPU correction field" },  .{ .val = 0xa1, .str = "No policy is currently limiting for the specified domain ID" },
    .{ .val = 0xc4, .str = "No space available" },                                 .{ .val = 0xd4, .str = "Insufficient privilege level due wrong responder LUN" },
    .{ .val = 0xd5, .str = "Policy exists and param unchangeable while enabled" }, .{ .val = 0xd6, .str = "Command subfunction disabled or unavailable" },
    .{ .val = 0xff, .str = null },
};

fn opt(args: []const ?[*:0]u8, idx: usize) ?[*:0]u8 {
    return if (idx < args.len) args[idx] else null;
}
fn val(table: []const Item, arg: ?[*:0]u8) u8 {
    const s = arg orelse return 0xff;
    for (table) |item| if (c.strcasecmp(s, item.text) == 0) return item.value;
    return 0xff;
}
fn text(table: []const Item, value: u8) [*:0]const u8 {
    for (table) |item| if (item.value == value) return item.text;
    _ = c.snprintf(&unknown, unknown.len, "Unknown (0x%x)", @as(c_uint, value));
    return @ptrCast(&unknown);
}
var unknown: [32]u8 = @splat(0);
fn pick(condition: bool, yes: [*:0]const u8, no: [*:0]const u8) [*:0]const u8 {
    return if (condition) yes else no;
}
fn usage(items: []const Item, title: [*:0]const u8) void {
    log.print(3, "\n%s", .{title});
    for (items) |item| log.print(3, "    %s    %s", .{ item.text, item.help });
    log.print(3, "", .{});
}
fn number(comptime T: type, arg: ?[*:0]u8) ?T {
    const s = arg orelse return null;
    var n: T = 0;
    const status = switch (T) {
        u8 => c.str2uchar(s, &n),
        u16 => c.str2ushort(s, &n),
        u32 => c.str2uint(s, &n),
        else => @compileError("unexpected numeric type"),
    };
    return if (status == 0) n else null;
}
fn word(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}
fn dword(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}
fn putWord(data: []u8, offset: usize, n: u16) void {
    std.mem.writeInt(u16, data[offset..][0..2], n, .little);
}
fn putDword(data: []u8, offset: usize, n: u32) void {
    std.mem.writeInt(u32, data[offset..][0..4], n, .little);
}
fn send(intf: *Intf, command: u8, bytes: []u8, min_size: usize) ?*Response {
    var request = std.mem.zeroes(Request);
    request.msg.netfn_lun.netfn = ipmi.NetFn.oem;
    request.msg.cmd = command;
    request.msg.data = bytes.ptr;
    request.msg.data_len = @intCast(bytes.len);
    const transmit = intf.sendrecv orelse return null;
    const response = transmit(intf, &request) orelse {
        log.print(3, "\n    No response to NM request", .{});
        return null;
    };
    if (command == 0xf2 and response.ccode == 0xa1) return response;
    if (response.ccode != 0) {
        log.print(3, "\n    NM request failed because: %s (%x)", .{ c.val2str(response.ccode, if (response.ccode >= 0x80 and response.ccode <= 0xd6) @ptrCast(&nm_ccodes) else c.completion_code_vals), @as(c_uint, response.ccode) });
        return null;
    }
    if (response.data_len < 1 or response.data[0] != 0x57) {
        if (response.data_len >= 1)
            _ = c.printf("\n    A valid NM command was not returned! (%x)", @as(c_uint, response.data[0]))
        else
            log.print(3, "\n    No response to NM request", .{});
        return null;
    }
    if (response.data_len < min_size or response.data_len > ipmi.buf_size) {
        log.print(3, "NM response is too short or malformed", .{});
        return null;
    }
    return response;
}
fn header(comptime n: usize) [n]u8 {
    var bytes: [n]u8 = @splat(0);
    bytes[0] = 0x57;
    bytes[1] = 1;
    return bytes;
}
fn nmDiscover(intf: *Intf) c_int {
    var data = header(3);
    const rsp = send(intf, 0xca, &data, 8) orelse return -1;
    _ = c.printf("    Node Manager Version %s\n", text(&versions, rsp.data[3]));
    _ = c.printf("    revision %d.%d%d  patch version %d\n", @as(c_int, rsp.data[6]), @as(c_int, rsp.data[7] >> 4), @as(c_int, rsp.data[7] & 0xf), @as(c_int, rsp.data[5]));
    return 0;
}
fn nmCapabilities(intf: *Intf, args: []const ?[*:0]u8) c_int {
    var domain: u8 = 0;
    var trigger: u8 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        switch (val(&caps_options, args[i])) {
            1 => {
                domain = val(&domains, opt(args, i + 1));
                if (domain == 0xff) {
                    usage(&domains, "Domain Scope:");
                    return -1;
                }
            },
            2 => trigger = 1,
            3 => trigger = 2,
            4 => trigger = 3,
            5 => trigger = 4,
            else => {
                usage(&caps_options, "Capability commands");
                return -1;
            },
        }
    }
    var msg = header(5);
    msg[3] = domain;
    msg[4] = trigger | 0x10;
    const rsp = send(intf, 0xc9, &msg, 21) orelse return -1;
    const d = &rsp.data;
    if (c.csv_output != 0) {
        _ = c.printf("%d,%u,%u,%u,%u,%u,%u,%s\n", @as(c_int, d[3]), @as(c_uint, word(d, 4)), @as(c_uint, word(d, 6)), dword(d, 8) / 1000, dword(d, 12) / 1000, @as(c_uint, word(d, 16)), @as(c_uint, word(d, 18)), text(&domains, d[20] & 0xf));
        return 0;
    }
    _ = c.printf("    power policies:\t\t%d\n", @as(c_int, d[3]));
    switch (trigger) {
        0 => _ = c.printf("    max_power\t\t%7u Watts\n    min_power\t\t%7u Watts\n", @as(c_uint, word(d, 4)), @as(c_uint, word(d, 6))),
        1 => _ = c.printf("    max_temp\t\t%7u C\n    min_temp\t\t%7u C\n", @as(c_uint, word(d, 4)), @as(c_uint, word(d, 6))),
        2, 3 => _ = c.printf("    max_time\t\t%7u Secs\n    min_time\t\t%7u Secs\n", @as(c_uint, word(d, 4) / 10), @as(c_uint, word(d, 6) / 10)),
        else => {},
    }
    _ = c.printf("    min_corr\t\t%7u secs\n    max_corr\t\t%7u secs\n", dword(d, 8) / 1000, dword(d, 12) / 1000);
    _ = c.printf("    min_stats\t\t%7u secs\n    max_stats\t\t%7u secs\n", @as(c_uint, word(d, 16)), @as(c_uint, word(d, 18)));
    _ = c.printf("    domain scope:\t%s\n", text(&domains, d[20] & 0xf));
    return 0;
}
fn nmControl(intf: *Intf, args: []const ?[*:0]u8) c_int {
    const action = val(&ctl_actions, opt(args, 1));
    if (action == 0xff) {
        usage(&ctl_actions, "Control parameters:");
        usage(&ctl_scope, "control Scope (required):");
        return -1;
    }
    var scope: u8 = 0;
    var domain: u8 = 0;
    var policy_id: u8 = 0xff;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        scope = val(&ctl_scope, args[i]);
        if (scope == 0xff) {
            usage(&ctl_scope, "Control Scope (required):");
            return -1;
        }
        if (scope == 2) {
            domain = val(&domains, opt(args, i + 1));
            if (domain == 0xff) {
                usage(&domains, "Domain Scope:");
                return -1;
            }
        } else if (scope == 4) {
            policy_id = number(u8, opt(args, i + 1)) orelse {
                log.print(3, "Policy ID must be a positive integer (0-255)\n", .{});
                return -1;
            };
        }
    }
    var msg = header(6);
    msg[3] = scope | action;
    msg[4] = domain;
    msg[5] = policy_id;
    return if (send(intf, 0xc0, &msg, 1) == null) -1 else 0;
}
fn policyGet(intf: *Intf, domain: u8, id: u8) c_int {
    var msg = header(5);
    msg[3] = domain;
    msg[4] = id;
    const rsp = send(intf, 0xc2, &msg, 16) orelse return -1;
    const d = &rsp.data;
    if (c.csv_output != 0) {
        _ = c.printf("%s,0x%x,%s,%s,%s,%u,%u,%u,%u,%s\n", text(&domains, d[3] & 0xf), @as(c_uint, d[3]), pick(d[4] & 0x10 != 0, "power", "nopower "), text(&triggers, d[4] & 0xf), text(&exceptions, d[5]), @as(c_uint, word(d, 6)), dword(d, 8), @as(c_uint, word(d, 12)), @as(c_uint, word(d, 14)), pick(d[4] & 0x80 != 0, "volatile", "non-volatile"));
        return 0;
    }
    _ = c.printf("    Power domain:                             %s\n", text(&domains, d[3] & 0xf));
    _ = c.printf("    Policy is %s %s%s%s\n", pick(d[3] & 0x10 != 0, "enabled", "not enabled"), pick(d[3] & 0x20 != 0, "per Domain ", ""), pick(d[3] & 0x40 != 0, "Globally ", ""), pick(d[3] & 0x80 != 0, "via DCMI api ", ""));
    _ = c.printf("    Policy is %sa power control type.\n", pick(d[4] & 0x10 != 0, "", "not "));
    _ = c.printf("    Policy Trigger Type:                      %s\n", text(&triggers, d[4] & 0xf));
    _ = c.printf("    Correction Aggressiveness:                %s\n", text(&correction_results, (d[4] >> 5) & 3));
    _ = c.printf("    Policy Exception Actions:                 %s\n", text(&exceptions, d[5]));
    _ = c.printf("    Power Limit:                              %u Watts\n", @as(c_uint, word(d, 6)));
    _ = c.printf("    Correction Time Limit:                    %u milliseconds\n", dword(d, 8));
    _ = c.printf("    Trigger Limit:                            %u units\n", @as(c_uint, word(d, 12)));
    _ = c.printf("    Statistics Reporting Period:              %u seconds\n", @as(c_uint, word(d, 14)));
    _ = c.printf("    Policy retention:                         %s\n", pick(d[4] & 0x80 != 0, "volatile", "non-volatile"));
    if (id == 0 and d[3] & 0xf == 3)
        _ = c.printf("    HW Prot Power domain:                     %s\n", pick(d[4] & 0x80 != 0, "Secondary", "Primary"));
    return 0;
}
fn nmPolicy(intf: *Intf, args: []const ?[*:0]u8) c_int {
    const action = val(&policy_actions, opt(args, 1));
    if (action == 0xff) {
        usage(&policy_actions, "Policy commands");
        return -1;
    }
    var msg = header(17);
    var have_id = false;
    var i: usize = 2;
    while (i < args.len) {
        const option = val(&policy_opts, args[i]);
        const argument = opt(args, i + 1);
        switch (option) {
            1 => msg[3] |= 0x10,
            2 => {},
            3 => {
                const domain = val(&domains, argument);
                if (domain == 0xff) {
                    usage(&domains, "Domain Scope:");
                    return -1;
                }
                msg[3] |= domain & 0xf;
                i += 1;
            },
            4 => {
                const n = number(u16, argument) orelse {
                    _ = c.printf("Inlet Temp value must be 20-45.\n");
                    return -1;
                };
                msg[5] |= 1;
                putWord(&msg, 7, 0);
                putWord(&msg, 13, n);
                i += 1;
            },
            6 => {
                if (action != 5) {
                    const n = val(&correction, argument);
                    if (n == 0xff) {
                        usage(&correction, "Correction Actions");
                        return -1;
                    }
                    msg[5] |= n << 5;
                }
                i += 1;
            },
            8 => {
                const n = number(u16, argument) orelse {
                    _ = c.printf("Power limit value must be 0-500.\n");
                    return -1;
                };
                putWord(&msg, 7, n);
                i += 1;
            },
            9 => {
                const n = number(u32, argument) orelse {
                    _ = c.printf("Trigger Limit value must be positive integer.\n");
                    return -1;
                };
                putDword(&msg, 9, n);
                i += 1;
            },
            10 => {
                const n = number(u16, argument) orelse {
                    _ = c.printf("Statistics Reporting Period must be positive integer.\n");
                    return -1;
                };
                putWord(&msg, 15, n);
                i += 1;
            },
            11 => {
                msg[4] = number(u8, argument) orelse {
                    _ = c.printf("Policy ID must be a positive integer (0-255)\n");
                    return -1;
                };
                have_id = true;
                i += 1;
            },
            12 => msg[5] |= 0x80,
            13 => {
                const n = number(u16, argument) orelse {
                    _ = c.printf("number of cores disabled must be 1-127.\n");
                    return -1;
                };
                if (n < 1 or n > 127) {
                    _ = c.printf("number of cores disabled must be 1-127.\n");
                    return -1;
                }
                msg[5] |= 4;
                putWord(&msg, 7, n << 1);
                i += 1;
            },
            else => {
                usage(&policy_opts, if (action == 0) "Get Policy commands" else "Policy options");
                return -1;
            },
        }
        i += 1;
    }
    if (action == 6) {
        var limiting = header(4);
        limiting[3] = msg[3] & 0xf;
        // 0xa1 means no policy limits this domain, not a command failure.
        // The C caller turns both this and a valid response into `limit 0`.
        const rsp = send(intf, 0xf2, &limiting, 1);
        if (rsp == null) return -1;
        _ = c.printf("limit 0\n"); // C compares the response with -1, then prints the boolean.
        return 0;
    }
    if (!have_id) {
        usage(&stats_opts, "Missing policy_id parameter:");
        return -1;
    }
    if (action == 0) return policyGet(intf, msg[3], msg[4]);
    if (action == 4) msg[5] |= 0x10;
    return if (send(intf, 0xc1, &msg, 1) == null) -1 else 0;
}
fn parseStatsOptions(args: []const ?[*:0]u8, start: usize, domain: *u8, id: *u8, have_id: *bool) bool {
    var i = start;
    while (i < args.len) : (i += 2) {
        switch (val(&stats_opts, args[i])) {
            1 => {
                domain.* = val(&domains, opt(args, i + 1));
                if (domain.* == 0xff) {
                    usage(&domains, "Domain Scope:");
                    return false;
                }
            },
            2 => {
                id.* = number(u8, opt(args, i + 1)) orelse {
                    log.print(3, "Policy ID must be a positive integer (0-255)\n", .{});
                    return false;
                };
                have_id.* = true;
            },
            else => {
                usage(&stats_opts, "Control Scope options");
                return false;
            },
        }
    }
    return true;
}
fn nmStatistics(intf: *Intf, args: []const ?[*:0]u8) c_int {
    const mode = val(&stats_modes, opt(args, 1));
    if (mode == 0xff) {
        usage(&stats_modes, "Statistics commands");
        return -1;
    }
    var domain: u8 = 0;
    var id: u8 = 0xff;
    var have_id = false;
    if (!parseStatsOptions(args, 2, &domain, &id, &have_id)) return -1;
    const policy_mode = mode >= 0x11 and mode <= 0x13;
    if (policy_mode and !have_id) {
        usage(&stats_opts, "Missing policy_id parameter:");
        return -1;
    }
    var msg = header(6);
    msg[3] = mode;
    msg[4] = domain;
    msg[5] = id;
    const rsp = send(intf, 0xc8, &msg, 20) orelse return -1;
    const d = &rsp.data;
    const state = d[19];
    const admin = pick(state & 0x10 != 0, pick(policy_mode, "Policy Enabled", "Globally Enabled"), "Disabled");
    const operational = pick(state & 0x20 != 0, "active", "suspended");
    const measurement = pick(state & 0x40 != 0, "in progress", "suspended");
    const activation = pick(state & 0x80 != 0, "triggered", "not triggered");
    const ts = c.ipmi_timestamp_numeric(dword(d, 11));
    if (c.csv_output != 0) {
        _ = c.printf("%s,%s,%s,%s,%s,%d,%d,%d,%d,%s,%d\n", text(&domains, state & 0xf), admin, operational, measurement, activation, @as(c_int, word(d, 3)), @as(c_int, word(d, 5)), @as(c_int, word(d, 7)), @as(c_int, word(d, 9)), ts, @as(c_int, @bitCast(dword(d, 15))));
        return 0;
    }
    const unit: [*:0]const u8 = switch (mode) {
        1, 0x11 => "Watts",
        2, 0x12 => "Celsius",
        3 => "%",
        0x13 => " %",
        else => "",
    };
    _ = c.printf("    Power domain:                             %s\n", text(&domains, state & 0xf));
    _ = c.printf("    Policy/Global Admin state                 %s\n", admin);
    _ = c.printf("    Policy/Global Operational state           %s\n", operational);
    _ = c.printf("    Policy/Global Measurement state           %s\n", measurement);
    _ = c.printf("    Policy Activation state                   %s\n", activation);
    _ = c.printf("    Instantaneous reading:                    %8d %s\n", @as(c_int, word(d, 3)), unit);
    _ = c.printf("    Minimum during sampling period:           %8d %s\n", @as(c_int, word(d, 5)), unit);
    _ = c.printf("    Maximum during sampling period:           %8d %s\n", @as(c_int, word(d, 7)), unit);
    _ = c.printf("    Average reading over sample period:       %8d %s\n", @as(c_int, word(d, 9)), unit);
    _ = c.printf("    IPMI timestamp:                           %s\n", ts);
    _ = c.printf("    Sampling period:                          %08d Seconds.\n\n", @as(c_int, @bitCast(dword(d, 15))));
    return 0;
}
fn nmReset(intf: *Intf, args: []const ?[*:0]u8) c_int {
    const mode = val(&reset_modes, opt(args, 1));
    if (mode == 0xff) {
        usage(&reset_modes, "Reset Statistics Modes:");
        return -1;
    }
    var domain: u8 = 0;
    var id: u8 = 0xff;
    var have_id = false;
    if (!parseStatsOptions(args, 2, &domain, &id, &have_id)) return -1;
    if (mode != 0 and !have_id) {
        usage(&stats_opts, "Missing policy_id parameter:");
        return -1;
    }
    var msg = header(6);
    msg[3] = mode;
    msg[4] = domain;
    msg[5] = id;
    return if (send(intf, 0xc7, &msg, 1) == null) -1 else 0;
}
fn nmPowerRange(intf: *Intf, args: []const ?[*:0]u8) c_int {
    var msg = header(8);
    var minimum: u16 = 0xffff;
    var maximum: u16 = 0xffff;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        switch (val(&range_opts, args[i])) {
            1 => {
                msg[3] = val(&domains, opt(args, i + 1));
                if (msg[3] == 0xff) {
                    usage(&domains, "Domain Scope:");
                    return -1;
                }
            },
            2 => minimum = number(u16, opt(args, i + 1)) orelse {
                log.print(3, "Power minimum must be a positive integer.\n", .{});
                return -1;
            },
            3 => maximum = number(u16, opt(args, i + 1)) orelse {
                log.print(3, "Power maximum must be a positive integer.\n", .{});
                return -1;
            },
            else => {
                usage(&range_opts, "power range parameters:");
                return -1;
            },
        }
    }
    if (minimum == 0xffff or maximum == 0xffff) {
        log.print(3, "Missing parameters: nm power range min <minimum> max <maximum>.\n", .{});
        return -1;
    }
    putWord(&msg, 4, minimum);
    putWord(&msg, 6, maximum);
    return if (send(intf, 0xcb, &msg, 1) == null) -1 else 0;
}
fn nmAlert(intf: *Intf, args: []const ?[*:0]u8) c_int {
    const action = val(&alert_actions, opt(args, 1));
    if (action == 0xff) {
        usage(&alert_actions, "Alert commands");
        return -1;
    }
    if (action == 2) {
        var msg = header(3);
        const rsp = send(intf, 0xcf, &msg, 6) orelse return -1;
        const d = &rsp.data;
        if (c.csv_output != 0) {
            _ = c.printf("%d,%s,0x%x,%s,0x%x\n", @as(c_int, d[3] & 0xf), pick(d[3] & 0x80 != 0, "not registered", "registered"), @as(c_uint, d[4]), pick(d[5] & 0x80 != 0, "yes", "no"), @as(c_uint, d[5] & 0x7f));
            return 0;
        }
        _ = c.printf("    Alert Chan:                                  %d\n", @as(c_int, d[3] & 0xf));
        _ = c.printf("    Alert Receiver:                              %s\n", pick(d[3] & 0x80 != 0, "not registered", "registered"));
        _ = c.printf("    Alert Lan Destination:                       0x%x\n", @as(c_uint, d[4]));
        _ = c.printf("    Use Alert String:                            %s\n", pick(d[5] & 0x80 != 0, "yes", "no"));
        _ = c.printf("    Alert String Selector:                       0x%x\n", @as(c_uint, d[5] & 0x7f));
        return 0;
    }
    var chan: u8 = 0xff;
    var dest: u8 = 0xff;
    var string: u8 = 0;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        switch (val(&alert_opts, args[i])) {
            1 => {
                chan = number(u8, opt(args, i + 1)) orelse {
                    log.print(3, "Alert Lan chan must be a positive integer.\n", .{});
                    return -1;
                };
                if (action == 3) chan |= 0x80;
            },
            2 => dest = number(u8, opt(args, i + 1)) orelse {
                log.print(3, "Alert Destination must be a positive integer.\n", .{});
                return -1;
            },
            3 => {
                string = number(u8, opt(args, i + 1)) orelse {
                    log.print(3, "Alert String # must be a positive integer.\n", .{});
                    return -1;
                };
                string |= 0x80;
            },
            else => {
                usage(&alert_opts, "Set alert Parameters:");
                return -1;
            },
        }
    }
    if (chan == 0xff or dest == 0xff) {
        usage(&alert_opts, "Must set alert chan and dest params.");
        return -1;
    }
    var msg = [6]u8{ 0x57, 1, 0, chan, dest, string };
    return if (send(intf, 0xce, &msg, 1) == null) -1 else 0;
}
fn nmThreshold(intf: *Intf, args: []const ?[*:0]u8) c_int {
    const action = val(&threshold_actions, opt(args, 1));
    if (args.len < 4 or action == 0xff) {
        usage(&threshold_actions, "Threshold commands");
        return -1;
    }
    var msg = header(12);
    var domain: u8 = 0;
    var id: ?u8 = null;
    var count: usize = 0;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(args[i].?), "domain")) {
            domain = val(&domains, opt(args, i + 1));
            if (domain == 0xff) {
                usage(&domains, "Domain Scope:");
                return -1;
            }
            i += 1;
        } else if (std.mem.eql(u8, std.mem.span(args[i].?), "policy_id")) {
            id = number(u8, opt(args, i + 1)) orelse {
                log.print(3, "Policy ID must be a positive integer (0-255)\n", .{});
                return -1;
            };
            i += 1;
        } else {
            if (count >= 3) {
                log.print(3, "Set Threshold requires 1, 2, or 3 threshold integer values.\n", .{});
                return -1;
            }
            const n = number(u16, args[i]) orelse {
                log.print(3, "threshold value %d count must be a positive integer.\n", .{@as(c_int, @intCast(count + 1))});
                return -1;
            };
            putWord(&msg, 6 + 2 * count, n);
            count += 1;
        }
    }
    if (id == null) {
        usage(&stats_opts, "Missing policy_id parameter:");
        return -1;
    }
    msg[3] = domain;
    msg[4] = id.?;
    if (action == 2) {
        const rsp = send(intf, 0xc4, msg[0..5], 4) orelse return -1;
        if (rsp.data[3] > 3) {
            log.print(3, "NM threshold response has an invalid threshold count", .{});
            return -1;
        }
        const n: usize = @min(@as(usize, rsp.data[3]), 3);
        if (rsp.data_len < 4 + n * 2) {
            log.print(3, "NM threshold response is too short", .{});
            return -1;
        }
        var values = [3]u16{ 0, 0, 0 };
        for (0..n) |idx| values[idx] = word(&rsp.data, 4 + 2 * idx);
        _ = c.printf("    Alert Threshold domain:                   %s\n", text(&domains, domain));
        _ = c.printf("    Alert Threshold Policy ID:                %d\n", @as(c_int, id.?));
        for (values, 0..) |v, idx| {
            _ = c.printf("    Alert Threshold %d:                        %d\n", @as(c_int, @intCast(idx + 1)), @as(c_int, v));
        }
        return 0;
    }
    msg[5] = @intCast(count);
    return if (send(intf, 0xc3, msg[0 .. 6 + count * 2], 1) == null) -1 else 0;
}
fn nmSuspend(intf: *Intf, args: []const ?[*:0]u8) c_int {
    const action = val(&suspend_actions, opt(args, 1));
    if (args.len < 4 or action == 0xff) {
        usage(&suspend_actions, "Suspend commands");
        return -1;
    }
    var domain: u8 = 0;
    var id: ?u8 = null;
    var periods: [5][3]u8 = @splat(@splat(0));
    var count: usize = 0;
    var i: usize = 2;
    while (i < args.len) {
        if (std.mem.eql(u8, std.mem.span(args[i].?), "domain")) {
            domain = val(&domains, opt(args, i + 1));
            if (domain == 0xff) {
                usage(&domains, "Domain Scope:");
                return -1;
            }
            i += 2;
        } else if (std.mem.eql(u8, std.mem.span(args[i].?), "policy_id")) {
            id = number(u8, opt(args, i + 1)) orelse {
                log.print(3, "Policy ID must be a positive integer (0-255)\n", .{});
                return -1;
            };
            i += 2;
        } else {
            if (args.len - i < 3 or count >= periods.len) {
                log.print(3, "Error: suspend period requires a start, stop, and repeat values.\n", .{});
                return -1;
            }
            for (0..3) |j| periods[count][j] = number(u8, args[i + j]) orelse {
                log.print(3, "suspend period value %d unable to convert.\n", .{@as(c_int, @intCast(count))});
                return -1;
            };
            count += 1;
            i += 3;
        }
    }
    if (id == null) {
        usage(&stats_opts, "Missing policy_id parameter:");
        return -1;
    }
    var msg = header(21);
    msg[3] = domain;
    msg[4] = id.?;
    if (action == 1) {
        // C parsed periods, but never copied `count` into `struct nm_suspend`.
        // Retain its six-byte request while rejecting out-of-bounds argv.
        return if (send(intf, 0xc5, msg[0..6], 1) == null) -1 else 0;
    }
    const rsp = send(intf, 0xc6, msg[0..5], 4) orelse return -1;
    const total: usize = rsp.data[3];
    const received = (total + 2) / 3;
    if (total > 5 or rsp.data_len < 4 + received * 3) {
        log.print(3, "NM suspend response has an invalid period count", .{});
        return -1;
    }
    _ = c.printf("    Suspend Policy domain:                    %s\n", text(&domains, domain));
    _ = c.printf("    Suspend Policy Policy ID:                 %d\n", @as(c_int, id.?));
    if (total == 0) _ = c.printf("    No suspend Periods.\n");
    const days = [_][*:0]const u8{ "M", "Tu", "W", "Th", "F", "Sa", "Su" };
    // The C decoder advances one period for each three units of the reported
    // count, but prints `count` entries (the others were zero-initialized).
    for (0..received) |index| {
        periods[index] = rsp.data[4 + index * 3 ..][0..3].*;
    }
    for (0..total) |index| {
        const start = periods[index][0];
        const stop = periods[index][1];
        const repeat = periods[index][2];
        _ = c.printf("    Suspend Period %d:                         %02d:%02d to %02d:%02d", @as(c_int, @intCast(index)), @as(c_int, start / 10), @mod(@as(c_int, start) * 6, 60), @as(c_int, stop / 10), @mod(@as(c_int, stop) * 6, 60));
        if (repeat != 0) _ = c.printf(", ");
        for (days, 0..) |day, j| if ((repeat >> @intCast(j)) & 1 != 0) {
            _ = c.printf("%s", day);
        };
        _ = c.printf("\n");
    }
    return 0;
}

fn nmMain(intf_opt: ?*Intf, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
    const intf = intf_opt orelse return -1;
    const args: []const ?[*:0]u8 = if (argc > 0 and argv != null) argv.?[0..@intCast(argc)] else &.{};
    if (args.len == 0 or c.strcmp(args[0].?, "help") == 0) {
        usage(&commands, "Node Manager Interface commands");
        return -1;
    }
    const result: c_int = switch (val(&commands, args[0])) {
        0 => nmDiscover(intf),
        1 => nmCapabilities(intf, args),
        2 => nmControl(intf, args),
        3 => nmPolicy(intf, args),
        4 => nmStatistics(intf, args),
        5 => nmPowerRange(intf, args),
        6 => nmSuspend(intf, args),
        7 => nmReset(intf, args),
        8 => nmAlert(intf, args),
        9 => nmThreshold(intf, args),
        else => blk: {
            usage(&commands, "Node Manager Interface commands");
            break :blk 0;
        },
    };
    return if (result < 0) -1 else 0;
}

fn makeTable(comptime entries: []const Item) [entries.len + 1]c.struct_dcmi_cmd {
    var items: [entries.len + 1]c.struct_dcmi_cmd = undefined;
    for (entries, 0..) |entry, i| {
        items[i] = .{ .val = entry.value, .str = entry.text, .desc = entry.help };
    }
    items[entries.len] = .{ .val = 0xff, .str = null, .desc = null };
    return items;
}
const tables = struct {
    const cmds = makeTable(&commands);
    const ctl = makeTable(&ctl_actions);
    const ctl_domain = makeTable(&ctl_scope);
    const domain = makeTable(&domains);
    const version = makeTable(&versions);
    const capability = makeTable(&caps_options);
    const policy_type = makeTable(&triggers);
    const statistics_options = makeTable(&stats_opts);
    const statistics_mode = makeTable(&stats_modes);
    const policy_action = makeTable(&policy_actions);
    const policy_options = makeTable(&policy_opts);
    const trigger = makeTable(&.{
        .{ .value = 0, .text = "none" },  .{ .value = 1, .text = "temp" },
        .{ .value = 2, .text = "reset" }, .{ .value = 3, .text = "boot" },
    });
    const correction_action = makeTable(&correction);
    const correction_value = makeTable(&correction_results);
    const exception = makeTable(&exceptions);
    const reset = makeTable(&reset_modes);
    const power = makeTable(&range_opts);
    const alert = makeTable(&alert_actions);
    const alert_params = makeTable(&alert_opts);
    const thresholds = makeTable(&threshold_actions);
    const threshold_params = makeTable(&stats_opts);
    const suspend_cmds = makeTable(&suspend_actions);
};
pub fn exportSymbols() void {
    @setEvalBranchQuota(100_000);
    abi.assertCallSignature(@TypeOf(nmMain), @TypeOf(c.ipmi_nm_main));
    @export(&nmMain, .{ .name = "ipmi_nm_main", .linkage = .strong });
    @export(&tables.cmds, .{ .name = "nm_cmd_vals", .linkage = .strong });
    @export(&tables.ctl, .{ .name = "nm_ctl_cmds", .linkage = .strong });
    @export(&tables.ctl_domain, .{ .name = "nm_ctl_domain", .linkage = .strong });
    @export(&tables.domain, .{ .name = "nm_domain_vals", .linkage = .strong });
    @export(&tables.version, .{ .name = "nm_version_vals", .linkage = .strong });
    @export(&tables.capability, .{ .name = "nm_capability_opts", .linkage = .strong });
    @export(&tables.policy_type, .{ .name = "nm_policy_type_vals", .linkage = .strong });
    @export(&tables.statistics_options, .{ .name = "nm_stats_opts", .linkage = .strong });
    @export(&tables.statistics_mode, .{ .name = "nm_stats_mode", .linkage = .strong });
    @export(&tables.policy_action, .{ .name = "nm_policy_action", .linkage = .strong });
    @export(&tables.policy_options, .{ .name = "nm_policy_options", .linkage = .strong });
    @export(&tables.trigger, .{ .name = "nm_trigger", .linkage = .strong });
    @export(&tables.correction_action, .{ .name = "nm_correction", .linkage = .strong });
    @export(&tables.correction_value, .{ .name = "nm_correction_vals", .linkage = .strong });
    @export(&tables.exception, .{ .name = "nm_exception", .linkage = .strong });
    @export(&tables.reset, .{ .name = "nm_reset_mode", .linkage = .strong });
    @export(&tables.power, .{ .name = "nm_power_range", .linkage = .strong });
    @export(&tables.alert, .{ .name = "nm_alert_opts", .linkage = .strong });
    @export(&tables.alert_params, .{ .name = "nm_set_alert_param", .linkage = .strong });
    @export(&tables.thresholds, .{ .name = "nm_thresh_cmds", .linkage = .strong });
    @export(&tables.threshold_params, .{ .name = "nm_thresh_param", .linkage = .strong });
    @export(&tables.suspend_cmds, .{ .name = "nm_suspend_cmds", .linkage = .strong });
    @export(&nm_ccodes, .{ .name = "nm_ccode_vals", .linkage = .strong });
}
