//! Minimal line diff for failure reports.
//!
//! Not a general purpose diff: it trims the common prefix and suffix and prints
//! the differing block with `-expected` / `+actual` markers plus a little
//! context. That is enough to see what a port changed without pulling in a
//! dependency.

const std = @import("std");

pub const context_lines = 3;

pub fn write(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    label: []const u8,
    expected: []const u8,
    actual: []const u8,
) std.mem.Allocator.Error!void {
    try out.print(gpa, "  --- {s} ---\n", .{label});

    var expected_lines = try splitLines(gpa, expected);
    defer expected_lines.deinit(gpa);
    var actual_lines = try splitLines(gpa, actual);
    defer actual_lines.deinit(gpa);

    const e = expected_lines.items;
    const a = actual_lines.items;

    var prefix: usize = 0;
    while (prefix < e.len and prefix < a.len and std.mem.eql(u8, e[prefix], a[prefix])) prefix += 1;

    var suffix: usize = 0;
    while (suffix < e.len - prefix and suffix < a.len - prefix and
        std.mem.eql(u8, e[e.len - 1 - suffix], a[a.len - 1 - suffix])) suffix += 1;

    const start = prefix -| context_lines;
    var shown: usize = 0;
    var i = start;
    while (i < prefix) : (i += 1) {
        try out.print(gpa, "   {s}\n", .{e[i]});
    }
    for (e[prefix .. e.len - suffix]) |line| {
        try out.print(gpa, "  -{s}\n", .{line});
        shown += 1;
        if (shown > 200) {
            try out.appendSlice(gpa, "  ... (diff truncated)\n");
            return;
        }
    }
    for (a[prefix .. a.len - suffix]) |line| {
        try out.print(gpa, "  +{s}\n", .{line});
        shown += 1;
        if (shown > 200) {
            try out.appendSlice(gpa, "  ... (diff truncated)\n");
            return;
        }
    }
    const tail_end = @min(e.len, e.len - suffix + context_lines);
    i = e.len - suffix;
    while (i < tail_end) : (i += 1) {
        try out.print(gpa, "   {s}\n", .{e[i]});
    }
}

fn splitLines(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    if (text.len == 0) return list;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try list.append(gpa, line);
    // A trailing newline produces a final empty element; drop it so the diff
    // does not show a phantom line.
    if (list.items.len > 0 and list.items[list.items.len - 1].len == 0) _ = list.pop();
    return list;
}
