//! C ABI replacement for `lib/ipmi_cfgp.c`, used by the retained `lan6`
//! command. Nodes are allocated with libc malloc and owned by the context;
//! `ipmi_cfgp_uninit` releases them, including those appended by earlier
//! successful GETs if a later GET fails. All errors return -1; GET callbacks
//! may return their own error code, which the public GET maps to -1.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");

const Sel = c.struct_ipmi_cfgp_sel;
const Action = c.struct_ipmi_cfgp_action;
const Descriptor = extern struct {
    name: ?[*:0]const u8,
    format: ?[*:0]const u8,
    size: c_uint,
    traits: u32,
    specific: c_int,

    fn flags(p: *const Descriptor, comptime shift: u5, comptime bits: u5) u32 {
        const location = if (builtin.target.cpu.arch.endian() == .little)
            shift
        else
            @as(u5, @intCast(@as(u6, 32) - @as(u6, shift) - @as(u6, bits)));
        return (p.traits >> location) & ((@as(u32, 1) << bits) - 1);
    }

    fn access(p: *const Descriptor) u32 {
        return p.flags(0, 2);
    }
    fn isSet(p: *const Descriptor) bool {
        return p.flags(2, 1) != 0;
    }
    fn firstSet(p: *const Descriptor) c_int {
        return @intCast(p.flags(3, 1));
    }
    fn hasBlocks(p: *const Descriptor) bool {
        return p.flags(4, 1) != 0;
    }
    fn firstBlock(p: *const Descriptor) c_int {
        return @intCast(p.flags(5, 1));
    }
};

const Data = extern struct {
    next: ?*Data,
    sel: Sel,
    _data: [0]u8,

    fn bytes(node: *Data) [*]u8 {
        return @ptrCast(&node._data);
    }
};

const Handler = *const fn (?*anyopaque, *const Descriptor, *const Action, [*]u8) callconv(.c) c_int;
const Context = extern struct {
    set: ?[*]const Descriptor,
    count: c_int,
    handler: ?Handler,
    cmdname: ?[*:0]const u8,
    v: ?*Data,
    priv: ?*anyopaque,
};

fn descriptor(ctx: *Context, index: c_int) *const Descriptor {
    return &ctx.set.?[@intCast(index)];
}

fn allocate(p: *const Descriptor) ?*Data {
    const size = std.math.add(usize, @sizeOf(Data), p.size) catch return null;
    const raw = c.malloc(size) orelse return null;
    const node: *Data = @ptrCast(@alignCast(raw));
    @memset(@as([*]u8, @ptrCast(node))[0..size], 0);
    return node;
}

fn append(ctx: *Context, node: *Data) void {
    node.next = null;
    var tail = &ctx.v;
    while (tail.*) |item| tail = &item.next;
    tail.* = node;
}

fn init(ctx_opt: ?*Context, set: ?[*]const Descriptor, count: c_uint, cmdname: ?[*:0]const u8, handler: ?Handler, priv: ?*anyopaque) callconv(.c) c_int {
    const ctx = ctx_opt orelse return -1;
    if (set == null or cmdname == null or handler == null) return -1;
    ctx.* = std.mem.zeroes(Context);
    ctx.set = set;
    ctx.count = @bitCast(count);
    ctx.cmdname = cmdname;
    ctx.handler = handler;
    ctx.priv = priv;
    return 0;
}

fn uninit(ctx_opt: ?*Context) callconv(.c) c_int {
    const ctx = ctx_opt orelse return -1;
    while (ctx.v) |node| {
        ctx.v = node.next;
        c.free(node);
    }
    return 0;
}

fn usageOne(p: *const Descriptor, write: c_int) void {
    const name = p.name orelse return;
    if (write != 0 and p.format == null) return;
    const set_label: [*:0]const u8 = if (p.isSet()) " <set_sel>" else "";
    const block_label: [*:0]const u8 = if (p.hasBlocks()) " <block_sel>" else "";
    const format: [*:0]const u8 = if (write != 0) p.format.? else "";
    _ = c.printf(
        "    %s%s%s %s\n",
        name,
        set_label,
        block_label,
        format,
    );
}

fn usage(set: ?[*]const Descriptor, count: c_int, write: c_int) callconv(.c) void {
    const descriptors = set orelse return;
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const p = &descriptors[@intCast(i)];
        if (write != 0 and p.access() == c.CFGP_RDONLY) continue;
        if (write == 0 and p.access() == c.CFGP_WRONLY) continue;
        usageOne(p, write);
    }
}

fn parseSel(ctx_opt: ?*Context, argc: c_int, argv: [*c][*c]const u8, sel_opt: ?*Sel) callconv(.c) c_int {
    const ctx = ctx_opt orelse return -1;
    const sel = sel_opt orelse return -1;
    if (argv == null) return -1;
    sel.* = .{ .param = -1, .set = -1, .block = -1 };
    if (argc == 0) return 0;

    var index: c_int = 0;
    while (index < ctx.count) : (index += 1) {
        const p = descriptor(ctx, index);
        if (p.name == null or c.strcasecmp(p.name.?, argv[0]) != 0) continue;
        sel.param = index;
        sel.set = if (p.isSet()) -1 else 0;
        sel.block = if (p.hasBlocks()) -1 else 0;
        if (argc == 1 or !p.isSet()) return 1;
        if (c.str2int(argv[1], &sel.set) != 0 or sel.set < 0 or (sel.set == 0 and p.firstSet() != 0)) {
            log.print(log.Level.err, "invalid set selector", .{});
            return -1;
        }
        if (argc == 2 or !p.hasBlocks()) return 2;
        if (c.str2int(argv[2], &sel.block) != 0 or sel.block < 0 or (sel.block == 0 and p.firstBlock() != 0)) {
            log.print(log.Level.err, "invalid block selector", .{});
            return -1;
        }
        return 3;
    }
    log.print(log.Level.err, "invalid parameter", .{});
    return -1;
}

fn parseData(ctx_opt: ?*Context, sel_opt: ?*const Sel, argc: c_int, argv: [*c][*c]const u8) callconv(.c) c_int {
    const ctx = ctx_opt orelse return -1;
    const sel = sel_opt orelse return -1;
    if (argv == null) return -1;
    if (sel.param < 0 or sel.param >= ctx.count) {
        log.print(log.Level.err, "invalid parameter, must be one of:", .{});
        usage(ctx.set, ctx.count, 1);
        return -1;
    }
    if (sel.set == -1) {
        log.print(log.Level.err, "set selector is not specified", .{});
        return -1;
    }
    if (sel.block == -1) {
        log.print(log.Level.err, "block selector is not specified", .{});
        return -1;
    }
    const p = descriptor(ctx, sel.param);
    if (p.size == 0) return -1;
    const node = allocate(p) orelse return -1;
    var action = std.mem.zeroes(Action);
    action.type = c.CFGP_PARSE;
    action.set = sel.set;
    action.block = sel.block;
    action.argc = argc;
    action.argv = argv;
    if (ctx.handler.?(ctx.priv, p, &action, node.bytes()) != 0) {
        usage(@ptrCast(p), 1, 1);
        c.free(node);
        return -1;
    }
    node.sel = sel.*;
    append(ctx, node);
    return 0;
}

fn getParam(ctx: *Context, index: c_int, requested_set: c_int, requested_block: c_int, quiet: c_int) c_int {
    const p = descriptor(ctx, index);
    if (p.size == 0) return -1;
    var set = requested_set;
    var block = requested_block;
    if (set == -1 and !p.isSet()) set = 0;
    if (block == -1 and !p.hasBlocks()) block = 0;
    var action = std.mem.zeroes(Action);
    action.type = c.CFGP_GET;
    action.quiet = quiet;
    var current_set: c_int = if (set == -1) p.firstSet() else set;
    while (true) {
        var current_block: c_int = if (block == -1) p.firstBlock() else block;
        var ret: c_int = 0;
        while (true) {
            const node = allocate(p) orelse return -1;
            action.set = current_set;
            action.block = current_block;
            ret = ctx.handler.?(ctx.priv, p, &action, node.bytes());
            if (ret != 0) {
                c.free(node);
                if (action.quiet == 0) return ret;
                break;
            }
            node.sel = .{ .param = index, .set = current_set, .block = current_block };
            append(ctx, node);
            current_block +%= 1;
            action.quiet = 1;
            if (block != -1) break;
        }
        if (ret != 0 and current_block == p.firstBlock()) break;
        current_set +%= 1;
        if (set != -1) break;
    }
    return 0;
}

fn get(ctx_opt: ?*Context, sel_opt: ?*const Sel) callconv(.c) c_int {
    const ctx = ctx_opt orelse return -1;
    const sel = sel_opt orelse return -1;
    if (sel.param != -1) {
        if (sel.param < 0 or sel.param >= ctx.count) return -1;
        return if (getParam(ctx, sel.param, sel.set, sel.block, 0) != 0) -1 else 0;
    }
    var index: c_int = 0;
    while (index < ctx.count) : (index += 1) {
        if (descriptor(ctx, index).access() == c.CFGP_WRONLY) continue;
        if (getParam(ctx, index, sel.set, sel.block, 1) != 0) return -1;
    }
    return 0;
}

fn doAction(ctx_opt: ?*Context, action_type: c_int, sel_opt: ?*const Sel, file: ?*c.FILE, filter: c_int) c_int {
    const ctx = ctx_opt orelse return -1;
    const sel = sel_opt orelse return -1;
    var action = std.mem.zeroes(Action);
    action.type = action_type;
    action.file = file;
    var node = ctx.v;
    while (node) |item| : (node = item.next) {
        if (sel.param != -1 and sel.param != item.sel.param) continue;
        if (sel.set != -1 and sel.set != item.sel.set) continue;
        if (sel.block != -1 and sel.block != item.sel.block) continue;
        if (item.sel.param < 0 or item.sel.param >= ctx.count) return -1;
        const p = descriptor(ctx, item.sel.param);
        if (p.access() == @as(u32, @intCast(filter))) continue;
        action.set = item.sel.set;
        action.block = item.sel.block;
        if (action_type == c.CFGP_SAVE) {
            _ = c.fprintf(file, "%s %s ", ctx.cmdname.?, p.name.?);
            if (p.isSet()) _ = c.fprintf(file, "%d ", item.sel.set);
            if (p.hasBlocks()) _ = c.fprintf(file, "%d ", item.sel.block);
        }
        const ret = ctx.handler.?(ctx.priv, p, &action, item.bytes());
        if (action_type == c.CFGP_SAVE) _ = c.fputc('\n', file);
        if (ret != 0) return -1;
    }
    return 0;
}

fn setData(ctx: ?*Context, sel: ?*const Sel) callconv(.c) c_int {
    return doAction(ctx, c.CFGP_SET, sel, null, c.CFGP_RDONLY);
}
fn save(ctx: ?*Context, sel: ?*const Sel, file: ?*c.FILE) callconv(.c) c_int {
    if (file == null) return -1;
    return doAction(ctx, c.CFGP_SAVE, sel, file, c.CFGP_RDONLY);
}
fn print(ctx: ?*Context, sel: ?*const Sel, file: ?*c.FILE) callconv(.c) c_int {
    if (file == null) return -1;
    return doAction(ctx, c.CFGP_PRINT, sel, file, c.CFGP_RESERVED);
}

pub fn exportSymbols() void {
    abi.assertOpaqueLayout(Descriptor, .{
        .size = c.ABI_SIZEOF_ipmi_cfgp,
        .alignment = c.ABI_ALIGNOF_ipmi_cfgp,
        .fields = &.{
            .{ .name = "name", .offset = c.ABI_OFFSETOF_ipmi_cfgp__name },
            .{ .name = "format", .offset = c.ABI_OFFSETOF_ipmi_cfgp__format },
            .{ .name = "size", .offset = c.ABI_OFFSETOF_ipmi_cfgp__size },
            .{ .name = "specific", .offset = c.ABI_OFFSETOF_ipmi_cfgp__specific },
        },
    });
    abi.assertLayout(Context, c.struct_ipmi_cfgp_ctx);
    abi.assertLayout(Data, c.struct_ipmi_cfgp_data);
    abi.assertCallSignature(@TypeOf(init), @TypeOf(c.ipmi_cfgp_init));
    abi.assertCallSignature(@TypeOf(uninit), @TypeOf(c.ipmi_cfgp_uninit));
    abi.assertCallSignature(@TypeOf(usage), @TypeOf(c.ipmi_cfgp_usage));
    abi.assertCallSignature(@TypeOf(parseSel), @TypeOf(c.ipmi_cfgp_parse_sel));
    abi.assertCallSignature(@TypeOf(parseData), @TypeOf(c.ipmi_cfgp_parse_data));
    abi.assertCallSignature(@TypeOf(get), @TypeOf(c.ipmi_cfgp_get));
    abi.assertCallSignature(@TypeOf(setData), @TypeOf(c.ipmi_cfgp_set));
    abi.assertCallSignature(@TypeOf(save), @TypeOf(c.ipmi_cfgp_save));
    abi.assertCallSignature(@TypeOf(print), @TypeOf(c.ipmi_cfgp_print));
    @export(&init, .{ .name = "ipmi_cfgp_init", .linkage = .strong });
    @export(&uninit, .{ .name = "ipmi_cfgp_uninit", .linkage = .strong });
    @export(&usage, .{ .name = "ipmi_cfgp_usage", .linkage = .strong });
    @export(&parseSel, .{ .name = "ipmi_cfgp_parse_sel", .linkage = .strong });
    @export(&parseData, .{ .name = "ipmi_cfgp_parse_data", .linkage = .strong });
    @export(&get, .{ .name = "ipmi_cfgp_get", .linkage = .strong });
    @export(&setData, .{ .name = "ipmi_cfgp_set", .linkage = .strong });
    @export(&save, .{ .name = "ipmi_cfgp_save", .linkage = .strong });
    @export(&print, .{ .name = "ipmi_cfgp_print", .linkage = .strong });
}
