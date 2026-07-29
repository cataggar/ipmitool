//! The transport fixture transcript: a line oriented, byte level record of a
//! whole UDP exchange.
//!
//! One transcript per case.  It is produced by the model BMC in
//! `Bmc.zig` while the tool under test runs, and it is what gets committed
//! under `tests/transport/fixtures/`.  Checking a build means producing the
//! transcript again and comparing it as text: any difference in the bytes on
//! the wire, in their order, in their length, or in the BMC's verdict about
//! them, shows up as a diff.
//!
//! Format:
//!
//!     # comment lines carry the case name and the argv
//!     001 --> 23  ipmi.v15 rq        one line per datagram: index, direction,
//!       ssn authtype=00 ...          length, and a decode of the framing
//!       msg rsaddr=20 netfn=06 ...
//!       dat 0e 04
//!       raw 06 00 ff 07 00 00 00 00 00 00 00 00 09 20 18 c8
//!       raw 81 04 38 8e 04 b5
//!     exit 0
//!     out |Device ID  : 32
//!     err |
//!
//! `-->` is a datagram from the tool under test to the model BMC, `<--` the
//! other way.  `??` in a `raw` line marks a byte that is allowed to vary; see
//! the header comment in `Bmc.zig` for the exhaustive list of what is masked.
//!
//! The index is monotonic across *both* directions, so a dropped or duplicated
//! datagram shifts every following line and cannot be mistaken for a change in
//! content.

const std = @import("std");
const Io = std.Io;

pub const Direction = enum { in, out };

/// A half-open byte range rendered as `??`.
pub const Span = struct {
    start: usize,
    len: usize,

    pub fn lessThan(_: void, a: Span, b: Span) bool {
        return a.start < b.start;
    }

    fn covers(spans: []const Span, i: usize) bool {
        for (spans) |s| {
            if (i >= s.start and i < s.start + s.len) return true;
        }
        return false;
    }
};

gpa: std.mem.Allocator,
buf: std.ArrayList(u8) = .empty,

const Transcript = @This();

pub fn init(gpa: std.mem.Allocator) Transcript {
    return .{ .gpa = gpa };
}

pub fn deinit(t: *Transcript) void {
    t.buf.deinit(t.gpa);
}

pub fn text(t: *const Transcript) []const u8 {
    return t.buf.items;
}

pub fn print(t: *Transcript, comptime fmt: []const u8, args: anytype) !void {
    try t.buf.print(t.gpa, fmt, args);
}

/// Record one datagram: the header line, then the hex.
pub fn frame(
    t: *Transcript,
    index: u32,
    dir: Direction,
    bytes: []const u8,
    spans: []const Span,
    name: []const u8,
) !void {
    try t.print("{d:0>3} {s} {d} {s}\n", .{
        index,
        if (dir == .in) "-->" else "<--",
        bytes.len,
        name,
    });
    try t.hexField("  raw", bytes, spans);
}

/// A named hex field, wrapped at 16 bytes per line, with `spans` masked.
pub fn hexField(t: *Transcript, label: []const u8, bytes: []const u8, spans: []const Span) !void {
    if (bytes.len == 0) {
        try t.print("{s} -\n", .{label});
        return;
    }
    var i: usize = 0;
    while (i < bytes.len) {
        try t.print("{s}", .{label});
        const end = @min(i + 16, bytes.len);
        while (i < end) : (i += 1) {
            if (Span.covers(spans, i)) {
                try t.print(" ??", .{});
            } else {
                try t.print(" {x:0>2}", .{bytes[i]});
            }
        }
        try t.print("\n", .{});
    }
}

/// A block of program output, one `label |line` per line so that trailing
/// whitespace and empty lines survive a round trip through the file.
pub fn outputBlock(t: *Transcript, label: []const u8, data: []const u8) !void {
    if (data.len == 0) {
        try t.print("{s} -\n", .{label});
        return;
    }
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        // A trailing newline yields a final empty piece; do not emit it.
        if (it.index == null and line.len == 0) break;
        try t.print("{s} |{s}\n", .{ label, line });
    }
}

/// A unified-ish diff of two transcripts, good enough to point at the first
/// divergence without pulling in a diff library.
pub fn diff(gpa: std.mem.Allocator, expected: []const u8, actual: []const u8, out: *Io.Writer) !void {
    var e = std.mem.splitScalar(u8, expected, '\n');
    var a = std.mem.splitScalar(u8, actual, '\n');
    var el: std.ArrayList([]const u8) = .empty;
    defer el.deinit(gpa);
    var al: std.ArrayList([]const u8) = .empty;
    defer al.deinit(gpa);
    while (e.next()) |l| try el.append(gpa, l);
    while (a.next()) |l| try al.append(gpa, l);

    var first: usize = 0;
    while (first < el.items.len and first < al.items.len and
        std.mem.eql(u8, el.items[first], al.items[first])) : (first += 1)
    {}

    const context = 6;
    const from = first -| context;
    const to = @min(@max(el.items.len, al.items.len), first + context + 1);
    try out.print("      first difference at line {d}\n", .{first + 1});
    var i = from;
    while (i < to) : (i += 1) {
        const ex: ?[]const u8 = if (i < el.items.len) el.items[i] else null;
        const ac: ?[]const u8 = if (i < al.items.len) al.items[i] else null;
        if (ex != null and ac != null and std.mem.eql(u8, ex.?, ac.?)) {
            try out.print("        {s}\n", .{ex.?});
        } else {
            if (ex) |x| try out.print("      - {s}\n", .{x});
            if (ac) |x| try out.print("      + {s}\n", .{x});
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "hex lines wrap at 16 bytes and honour masks" {
    var t: Transcript = .init(std.testing.allocator);
    defer t.deinit();
    var bytes: [20]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i);
    try t.hexField("  raw", &bytes, &.{.{ .start = 2, .len = 3 }});
    try std.testing.expectEqualStrings(
        \\  raw 00 01 ?? ?? ?? 05 06 07 08 09 0a 0b 0c 0d 0e 0f
        \\  raw 10 11 12 13
        \\
    , t.text());
}

test "an empty field is not an empty line" {
    var t: Transcript = .init(std.testing.allocator);
    defer t.deinit();
    try t.hexField("  dat", &.{}, &.{});
    try std.testing.expectEqualStrings("  dat -\n", t.text());
}

test "output blocks preserve empty lines but not the trailing newline" {
    var t: Transcript = .init(std.testing.allocator);
    defer t.deinit();
    try t.outputBlock("out", "a\n\nb\n");
    try std.testing.expectEqualStrings("out |a\nout |\nout |b\n", t.text());
}
