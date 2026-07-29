//! Recorded IPMI transcripts for the `dummy` interface.
//!
//! A transcript is a list of response *rules*. When the binary under test sends
//! a request over the dummy socket, the first rule that matches and still has
//! uses left produces the response. Matching on netfn/cmd/data (rather than a
//! rigid sequence) keeps transcripts small and lets a single rule serve the
//! repeated reads that FRU/SDR/SEL walking performs.
//!
//! The *order and content* of the requests is still checked: the harness writes
//! every exchange into the `requests` section of the snapshot, so a port that
//! sends different IPMI traffic fails even when its printed output is identical.
//!
//! Grammar (`#` starts a comment):
//!
//!     default_ccode 0xc1      # reply for requests no rule matches (default 0xc1)
//!
//!     respond get_device_id   # optional name, shown in the request log
//!       netfn 0x06            # required
//!       cmd   0x01            # required
//!       lun   0x00            # optional extra match
//!       match 00 01           # optional match on a prefix of the request data
//!       times 1               # optional; default: unlimited
//!       ccode 0x00            # default 0x00
//!       seq   0x00            # response header sequence byte; default 0x00
//!       data  20 81 02        # repeatable; concatenated; hex.zig grammar
//!       data  @sdr/full.hex   # ... including @include of a byte-level fixture
//!     end
//!
//! Commands that read a large structure in pieces (Get SDR, Read FRU Data)
//! need the response to depend on the offset and length in the request. A
//! `partial` rule does that: `blob` holds the whole structure and `partial`
//! says where the offset and the byte count live in the request.
//!
//!     respond read_fru_data
//!       netfn 0x0a
//!       cmd   0x11
//!       partial 1 2 3 count_prefix  # offset = request[1..2] LE, count = request[3],
//!                                   # reply starts with the number of bytes returned
//!       blob  @fru/board.hex
//!     end
//!
//! `partial <offset index> <offset width> <count index> [count_prefix]` slices
//! `blob[offset .. offset + count]`, clamped to the end of the blob. An offset
//! past the end yields completion code 0xc9 (parameter out of range), which is
//! what a real BMC does. Any `data` bytes are emitted first, before the slice.

const std = @import("std");
const Io = std.Io;
const hex = @import("hex.zig");

const Transcript = @This();

pub const Partial = struct {
    offset_index: u8,
    offset_width: u8,
    count_index: u8,
    count_prefix: bool,
};

pub const Rule = struct {
    name: []const u8,
    netfn: u8,
    cmd: u8,
    lun: ?u8 = null,
    match: []const u8 = &.{},
    times: ?u32 = null,
    ccode: u8 = 0,
    seq: u8 = 0,
    data: []const u8 = &.{},
    blob: []const u8 = &.{},
    partial: ?Partial = null,
    used: u32 = 0,
};

path: []const u8,
rules: []Rule,
default_ccode: u8 = 0xc1,

pub const Error = error{BadTranscript} || hex.Error;

pub fn load(ctx: hex.Context, transcripts_dir: []const u8, name: []const u8) Error!Transcript {
    const gpa = ctx.gpa;
    const path = try std.fs.path.join(gpa, &.{ transcripts_dir, name });
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, path, gpa, .unlimited) catch {
        try ctx.diag.print(gpa, "cannot read transcript '{s}'", .{path});
        return error.BadTranscript;
    };
    defer gpa.free(text);

    var rules: std.ArrayList(Rule) = .empty;
    var default_ccode: u8 = 0xc1;

    var current: ?Rule = null;
    var have_netfn = false;
    var have_cmd = false;
    var data: std.ArrayList(u8) = .empty;
    var blob: std.ArrayList(u8) = .empty;

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = hex.stripComment(raw_line);
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const key = it.next() orelse continue;
        const rest = std.mem.trim(u8, it.rest(), " \t\r");

        if (std.mem.eql(u8, key, "default_ccode")) {
            default_ccode = hex.parseByte(rest) orelse
                return fail(ctx, path, line_no, "default_ccode is not a hex byte");
        } else if (std.mem.eql(u8, key, "respond")) {
            if (current != null) return fail(ctx, path, line_no, "nested 'respond' (missing 'end')");
            current = .{
                .name = if (rest.len != 0)
                    try gpa.dupe(u8, rest)
                else
                    try std.fmt.allocPrint(gpa, "rule{d}", .{rules.items.len}),
                .netfn = 0,
                .cmd = 0,
            };
            have_netfn = false;
            have_cmd = false;
            data.clearRetainingCapacity();
            blob.clearRetainingCapacity();
        } else if (std.mem.eql(u8, key, "end")) {
            var rule = current orelse return fail(ctx, path, line_no, "'end' without 'respond'");
            if (!have_netfn or !have_cmd)
                return fail(ctx, path, line_no, "'respond' block needs both netfn and cmd");
            rule.data = try gpa.dupe(u8, data.items);
            rule.blob = try gpa.dupe(u8, blob.items);
            if (rule.partial != null and rule.blob.len == 0)
                return fail(ctx, path, line_no, "'partial' rule needs a 'blob'");
            try rules.append(gpa, rule);
            current = null;
        } else {
            if (current == null) return fail(ctx, path, line_no, "directive outside of a 'respond' block");
            const rule = &current.?;
            if (std.mem.eql(u8, key, "netfn")) {
                rule.netfn = hex.parseByte(rest) orelse
                    return fail(ctx, path, line_no, "netfn is not a hex byte");
                have_netfn = true;
            } else if (std.mem.eql(u8, key, "cmd")) {
                rule.cmd = hex.parseByte(rest) orelse
                    return fail(ctx, path, line_no, "cmd is not a hex byte");
                have_cmd = true;
            } else if (std.mem.eql(u8, key, "lun")) {
                rule.lun = hex.parseByte(rest) orelse
                    return fail(ctx, path, line_no, "lun is not a hex byte");
            } else if (std.mem.eql(u8, key, "ccode")) {
                rule.ccode = hex.parseByte(rest) orelse
                    return fail(ctx, path, line_no, "ccode is not a hex byte");
            } else if (std.mem.eql(u8, key, "seq")) {
                rule.seq = hex.parseByte(rest) orelse
                    return fail(ctx, path, line_no, "seq is not a hex byte");
            } else if (std.mem.eql(u8, key, "times")) {
                const n = hex.parseUsize(rest) orelse
                    return fail(ctx, path, line_no, "times is not a number");
                rule.times = @intCast(n);
            } else if (std.mem.eql(u8, key, "match")) {
                var m: std.ArrayList(u8) = .empty;
                defer m.deinit(gpa);
                try hex.parseTextInto(ctx, path, rest, &m, 0);
                rule.match = try gpa.dupe(u8, m.items);
            } else if (std.mem.eql(u8, key, "data")) {
                try hex.parseTextInto(ctx, path, rest, &data, 0);
            } else if (std.mem.eql(u8, key, "blob")) {
                try hex.parseTextInto(ctx, path, rest, &blob, 0);
            } else if (std.mem.eql(u8, key, "partial")) {
                var p = std.mem.tokenizeAny(u8, rest, " \t\r");
                const oi = hex.parseUsize(p.next() orelse "") orelse
                    return fail(ctx, path, line_no, "partial needs an offset index");
                const ow = hex.parseUsize(p.next() orelse "") orelse
                    return fail(ctx, path, line_no, "partial needs an offset width");
                const ci = hex.parseUsize(p.next() orelse "") orelse
                    return fail(ctx, path, line_no, "partial needs a count index");
                if (ow != 1 and ow != 2)
                    return fail(ctx, path, line_no, "partial offset width must be 1 or 2");
                var count_prefix = false;
                if (p.next()) |flag| {
                    if (!std.mem.eql(u8, flag, "count_prefix"))
                        return fail(ctx, path, line_no, "partial: expected 'count_prefix'");
                    count_prefix = true;
                }
                rule.partial = .{
                    .offset_index = @intCast(oi),
                    .offset_width = @intCast(ow),
                    .count_index = @intCast(ci),
                    .count_prefix = count_prefix,
                };
            } else {
                return fail(ctx, path, line_no, "unknown transcript directive");
            }
        }
    }
    if (current != null) return fail(ctx, path, line_no, "missing 'end' at end of transcript");
    data.deinit(gpa);
    blob.deinit(gpa);

    return .{
        .path = path,
        .rules = try rules.toOwnedSlice(gpa),
        .default_ccode = default_ccode,
    };
}

fn fail(ctx: hex.Context, path: []const u8, line_no: usize, msg: []const u8) Error {
    try ctx.diag.print(ctx.gpa, "{s}:{d}: {s}", .{ path, line_no, msg });
    return error.BadTranscript;
}

pub const Response = struct {
    ccode: u8,
    data: []const u8,
    rule_name: []const u8,
    /// `msg.seq` of the dummy response header.
    seq: u8 = 0,
};

/// Find the response for a request. Rules are considered in file order.
///
/// `scratch` is only used by `partial` rules; it is cleared on every call and
/// stays owned by the caller.
pub fn respond(
    t: *Transcript,
    gpa: std.mem.Allocator,
    scratch: *std.ArrayList(u8),
    netfn: u8,
    lun: u8,
    cmd: u8,
    data: []const u8,
) !Response {
    for (t.rules) |*rule| {
        if (rule.netfn != netfn or rule.cmd != cmd) continue;
        if (rule.lun) |l| if (l != lun) continue;
        if (rule.match.len != 0) {
            if (data.len < rule.match.len) continue;
            if (!std.mem.eql(u8, data[0..rule.match.len], rule.match)) continue;
        }
        if (rule.times) |limit| if (rule.used >= limit) continue;
        rule.used += 1;
        const p = rule.partial orelse
            return .{ .ccode = rule.ccode, .data = rule.data, .rule_name = rule.name, .seq = rule.seq };

        const need = @max(p.offset_index + p.offset_width, p.count_index + 1);
        if (data.len < need)
            return .{ .ccode = 0xc7, .data = &.{}, .rule_name = rule.name, .seq = rule.seq };

        var offset: usize = data[p.offset_index];
        if (p.offset_width == 2)
            offset |= @as(usize, data[p.offset_index + 1]) << 8;
        const want: usize = data[p.count_index];
        if (offset > rule.blob.len)
            return .{ .ccode = 0xc9, .data = &.{}, .rule_name = rule.name, .seq = rule.seq };
        const end = @min(rule.blob.len, offset + want);

        scratch.clearRetainingCapacity();
        try scratch.appendSlice(gpa, rule.data);
        if (p.count_prefix) try scratch.append(gpa, @intCast(end - offset));
        try scratch.appendSlice(gpa, rule.blob[offset..end]);
        return .{ .ccode = rule.ccode, .data = scratch.items, .rule_name = rule.name, .seq = rule.seq };
    }
    return .{ .ccode = t.default_ccode, .data = &.{}, .rule_name = "default" };
}
