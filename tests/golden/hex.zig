//! Hex fixture parsing.
//!
//! Byte-level fixtures are stored as human-reviewable text so that every byte
//! of an SDR record, FRU area, SEL entry, SPD image, ... is visible in a diff.
//!
//! Grammar (line oriented, `#` starts a comment that runs to end of line):
//!
//!     20 81 02 03           # plain hex bytes, whitespace separated
//!     @include sdr/common.hex   # splice in another fixture, relative to fixtures/
//!     @sdr/common.hex       # shorthand for @include
//!     @pad 16 0x00          # emit 16 copies of one byte
//!     @mark hdr             # remember the current offset under a name
//!     @checksum hdr         # emit the IPMI zero-checksum of bytes since @mark hdr
//!     @size8 hdr            # emit (bytes since @mark hdr) / 8 as one byte
//!     @size hdr             # emit (bytes since @mark hdr) as one byte
//!     @truncate 12          # keep only the first 12 bytes emitted so far
//!     @drop hdr 5           # delete 5 bytes starting at the @mark named hdr
//!     @md5 img              # emit the MD5 of the bytes since @mark img
//!                           # (HPM.1 images end with one)
//!     @poke img 63 0xff     # overwrite one byte at @mark img + 63; this is how
//!                           # the malformed variants are built, so a corrupt
//!                           # fixture differs from the good one by one line
//!     @poke img -1 0xff     # a negative offset counts back from the end
//!     @fill_size8 s area    # store len(@mark area)/8 into the byte at @mark s
//!     @fill_checksum s body # store the zero checksum of @mark body into the
//!                           # byte reserved at @mark s (for formats such as
//!                           # FRU multirecord that put a checksum before the
//!                           # bytes it covers)
//!
//! `@checksum`/`@size` exist so that malformed variants can be produced by
//! editing one byte without having to recompute checksums by hand.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    BadHexFixture,
    FixtureTooDeep,
} || std.mem.Allocator.Error;

const max_depth = 8;

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Root directory that `@include` paths are resolved against.
    fixtures_dir: []const u8,
    /// Filled in with a human readable reason when parsing fails.
    diag: *std.ArrayList(u8),
};

/// Parse a hex fixture file and return the raw bytes it describes.
pub fn parseFile(ctx: Context, rel_path: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.gpa);
    try parseFileInto(ctx, rel_path, &out, 0);
    return out.toOwnedSlice(ctx.gpa);
}

fn parseFileInto(ctx: Context, rel_path: []const u8, out: *std.ArrayList(u8), depth: u8) Error!void {
    if (depth >= max_depth) return error.FixtureTooDeep;
    const path = try std.fs.path.join(ctx.gpa, &.{ ctx.fixtures_dir, rel_path });
    defer ctx.gpa.free(path);
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .unlimited) catch {
        try ctx.diag.print(ctx.gpa, "cannot read hex fixture '{s}'", .{path});
        return error.BadHexFixture;
    };
    defer ctx.gpa.free(text);
    try parseTextInto(ctx, rel_path, text, out, depth);
}

/// Parse hex text (no file involved). Used for inline `data` lines in transcripts.
pub fn parseTextInto(
    ctx: Context,
    origin: []const u8,
    text: []const u8,
    out: *std.ArrayList(u8),
    depth: u8,
) Error!void {
    var marks: std.StringHashMapUnmanaged(usize) = .empty;
    defer marks.deinit(ctx.gpa);

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = stripComment(raw_line);
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        while (it.next()) |tok| {
            if (tok[0] == '@') {
                const directive = tok[1..];
                if (std.mem.eql(u8, directive, "include")) {
                    const arg = it.next() orelse
                        return fail(ctx, origin, line_no, "@include needs a path");
                    try parseFileInto(ctx, arg, out, depth + 1);
                } else if (std.mem.eql(u8, directive, "pad")) {
                    const count_s = it.next() orelse
                        return fail(ctx, origin, line_no, "@pad needs a count");
                    const byte_s = it.next() orelse
                        return fail(ctx, origin, line_no, "@pad needs a byte");
                    const count = parseUsize(count_s) orelse
                        return fail(ctx, origin, line_no, "@pad count is not a number");
                    const byte = parseByte(byte_s) orelse
                        return fail(ctx, origin, line_no, "@pad byte is not hex");
                    try out.appendNTimes(ctx.gpa, byte, count);
                } else if (std.mem.eql(u8, directive, "mark")) {
                    const name = it.next() orelse
                        return fail(ctx, origin, line_no, "@mark needs a name");
                    try marks.put(ctx.gpa, name, out.items.len);
                } else if (std.mem.eql(u8, directive, "checksum")) {
                    const name = it.next() orelse
                        return fail(ctx, origin, line_no, "@checksum needs a mark name");
                    const start = marks.get(name) orelse
                        return fail(ctx, origin, line_no, "@checksum refers to an unknown mark");
                    var sum: u8 = 0;
                    for (out.items[start..]) |b| sum -%= b;
                    try out.append(ctx.gpa, sum);
                } else if (std.mem.eql(u8, directive, "size") or std.mem.eql(u8, directive, "size8")) {
                    const name = it.next() orelse
                        return fail(ctx, origin, line_no, "@size needs a mark name");
                    const start = marks.get(name) orelse
                        return fail(ctx, origin, line_no, "@size refers to an unknown mark");
                    const len = out.items.len - start;
                    const value = if (std.mem.eql(u8, directive, "size8")) len / 8 else len;
                    if (value > 0xff) return fail(ctx, origin, line_no, "@size does not fit in a byte");
                    try out.append(ctx.gpa, @intCast(value));
                } else if (std.mem.eql(u8, directive, "md5")) {
                    const name = it.next() orelse
                        return fail(ctx, origin, line_no, "@md5 needs a mark name");
                    const start = marks.get(name) orelse
                        return fail(ctx, origin, line_no, "@md5 refers to an unknown mark");
                    var digest: [16]u8 = undefined;
                    std.crypto.hash.Md5.hash(out.items[start..], &digest, .{});
                    try out.appendSlice(ctx.gpa, &digest);
                } else if (std.mem.eql(u8, directive, "poke")) {
                    const base_s = it.next() orelse
                        return fail(ctx, origin, line_no, "@poke needs a mark name");
                    const off_s = it.next() orelse
                        return fail(ctx, origin, line_no, "@poke needs an offset");
                    const byte_s = it.next() orelse
                        return fail(ctx, origin, line_no, "@poke needs a byte");
                    const base = marks.get(base_s) orelse
                        return fail(ctx, origin, line_no, "@poke refers to an unknown mark");
                    const byte = parseByte(byte_s) orelse
                        return fail(ctx, origin, line_no, "@poke byte is not hex");
                    // A negative offset counts back from the end of the buffer,
                    // which is how a trailing checksum or digest is addressed.
                    const index: usize = if (off_s.len > 1 and off_s[0] == '-') blk: {
                        const back = parseUsize(off_s[1..]) orelse
                            return fail(ctx, origin, line_no, "@poke offset is not a number");
                        if (back > out.items.len)
                            return fail(ctx, origin, line_no, "@poke offset is before the start");
                        break :blk out.items.len - back;
                    } else blk: {
                        const off = parseUsize(off_s) orelse
                            return fail(ctx, origin, line_no, "@poke offset is not a number");
                        break :blk base + off;
                    };
                    if (index >= out.items.len)
                        return fail(ctx, origin, line_no, "@poke offset is past the end");
                    out.items[index] = byte;
                } else if (std.mem.eql(u8, directive, "fill_size") or
                    std.mem.eql(u8, directive, "fill_size8"))
                {
                    const slot_s = it.next() orelse
                        return fail(ctx, origin, line_no, "@fill_size needs a slot mark");
                    const region_s = it.next() orelse
                        return fail(ctx, origin, line_no, "@fill_size needs a region mark");
                    const slot = marks.get(slot_s) orelse
                        return fail(ctx, origin, line_no, "@fill_size: unknown slot mark");
                    const region = marks.get(region_s) orelse
                        return fail(ctx, origin, line_no, "@fill_size: unknown region mark");
                    if (slot >= out.items.len)
                        return fail(ctx, origin, line_no, "@fill_size slot is past the end");
                    const len = out.items.len - region;
                    const value = if (std.mem.eql(u8, directive, "fill_size8")) len / 8 else len;
                    if (value > 0xff) return fail(ctx, origin, line_no, "@fill_size does not fit in a byte");
                    out.items[slot] = @intCast(value);
                } else if (std.mem.eql(u8, directive, "fill_checksum")) {
                    const slot_s = it.next() orelse
                        return fail(ctx, origin, line_no, "@fill_checksum needs a slot mark");
                    const region_s = it.next() orelse
                        return fail(ctx, origin, line_no, "@fill_checksum needs a region mark");
                    const slot = marks.get(slot_s) orelse
                        return fail(ctx, origin, line_no, "@fill_checksum: unknown slot mark");
                    const region = marks.get(region_s) orelse
                        return fail(ctx, origin, line_no, "@fill_checksum: unknown region mark");
                    if (slot >= out.items.len)
                        return fail(ctx, origin, line_no, "@fill_checksum slot is past the end");
                    var sum: u8 = 0;
                    for (out.items[region..]) |b| sum -%= b;
                    // The slot byte itself is part of the region for a zero checksum.
                    if (region <= slot) sum +%= out.items[slot];
                    out.items[slot] = sum;
                } else if (std.mem.eql(u8, directive, "drop")) {
                    const name = it.next() orelse
                        return fail(ctx, origin, line_no, "@drop needs a mark name");
                    const count_s = it.next() orelse
                        return fail(ctx, origin, line_no, "@drop needs a count");
                    const start = marks.get(name) orelse
                        return fail(ctx, origin, line_no, "@drop refers to an unknown mark");
                    const count = parseUsize(count_s) orelse
                        return fail(ctx, origin, line_no, "@drop count is not a number");
                    if (start + count > out.items.len)
                        return fail(ctx, origin, line_no, "@drop reaches past the end");
                    std.mem.copyForwards(u8, out.items[start..], out.items[start + count ..]);
                    out.shrinkRetainingCapacity(out.items.len - count);
                } else if (std.mem.eql(u8, directive, "truncate")) {
                    const count_s = it.next() orelse
                        return fail(ctx, origin, line_no, "@truncate needs a length");
                    const count = parseUsize(count_s) orelse
                        return fail(ctx, origin, line_no, "@truncate length is not a number");
                    if (count > out.items.len)
                        return fail(ctx, origin, line_no, "@truncate length is past the end");
                    out.shrinkRetainingCapacity(count);
                } else if (std.mem.indexOfAny(u8, directive, "./") != null) {
                    // `@sdr/full.hex` is shorthand for `@include sdr/full.hex`.
                    try parseFileInto(ctx, directive, out, depth + 1);
                } else {
                    return fail(ctx, origin, line_no, "unknown @directive");
                }
                continue;
            }
            const byte = parseByte(tok) orelse
                return fail(ctx, origin, line_no, "not a hex byte");
            try out.append(ctx.gpa, byte);
        }
    }
}

fn fail(ctx: Context, origin: []const u8, line_no: usize, msg: []const u8) Error {
    try ctx.diag.print(ctx.gpa, "{s}:{d}: {s}", .{ origin, line_no, msg });
    return error.BadHexFixture;
}

pub fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |i| return line[0..i];
    return line;
}

pub fn parseByte(tok: []const u8) ?u8 {
    const t = if (tok.len > 2 and (std.mem.startsWith(u8, tok, "0x") or std.mem.startsWith(u8, tok, "0X")))
        tok[2..]
    else
        tok;
    if (t.len == 0 or t.len > 2) return null;
    return std.fmt.parseUnsigned(u8, t, 16) catch null;
}

pub fn parseUsize(tok: []const u8) ?usize {
    if (std.mem.startsWith(u8, tok, "0x") or std.mem.startsWith(u8, tok, "0X")) {
        return std.fmt.parseUnsigned(usize, tok[2..], 16) catch null;
    }
    return std.fmt.parseUnsigned(usize, tok, 10) catch null;
}

/// Format bytes as lower case hex separated by single spaces.
pub fn format(gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (bytes, 0..) |b, i| {
        if (i != 0) try out.append(gpa, ' ');
        try out.print(gpa, "{x:0>2}", .{b});
    }
    return out.toOwnedSlice(gpa);
}
